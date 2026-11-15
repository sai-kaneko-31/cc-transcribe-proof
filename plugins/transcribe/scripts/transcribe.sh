#!/usr/bin/env bash
# Wrapper around the AWS CLI for the transcribe plugin.
#
#   transcribe.sh estimate <file>
#       check the file, print duration, cost estimate and output paths (no AWS call)
#   transcribe.sh run <file> [--max-speakers N]
#       upload, transcribe with Amazon Transcribe (ja-JP), download, clean up AWS,
#       and write <name>.transcript.json and <name>.transcript.txt next to the file
#
# Exit codes: 0 ok, 1 an AWS call or the job failed, 2 bad input or setup,
# 3 the outputs are written but something could not be deleted from AWS.
#
# Written for bash 3.2 (the macOS default): no associative arrays, no mapfile.
# Cleanup state lives in plain variables set in the main shell; none of it is
# updated inside a command substitution, where the change would be lost.
set -u
set -o pipefail
IFS=$' \t\n'
umask 077

# ---- settings from the plugin's own variables, then a scrubbed environment ----
# Exported functions and variables from the caller are dropped, so a broader AWS
# key, a profile, an endpoint override or a PYTHONPATH in the caller's shell
# cannot reach the AWS CLI. Only what the CLI needs to run and reach the network
# is kept.
T_KEY_ID=${TRANSCRIBE_AWS_ACCESS_KEY_ID-}
T_SECRET=${TRANSCRIBE_AWS_SECRET_ACCESS_KEY-}
T_REGION=${TRANSCRIBE_AWS_REGION-}
T_BUCKET=${TRANSCRIBE_S3_BUCKET-}

for _name in $(compgen -A function); do unset -f "$_name"; done
for _name in $(compgen -e); do
  case "$_name" in
    PATH | HOME | PWD | LANG | LANGUAGE | LC_* | TMPDIR | TZ | USER | LOGNAME) ;;
    HTTP_PROXY | HTTPS_PROXY | NO_PROXY | ALL_PROXY | http_proxy | https_proxy | no_proxy | all_proxy) ;;
    AWS_CA_BUNDLE) ;;
    *) unset "$_name" 2> /dev/null ;;
  esac
done
unset _name

# ---- limits (constants; deliberately not overridable from the environment) ----
readonly MAX_SECONDS=7200     # 120 minutes: keeps one transcript small enough for the corrector
readonly MAX_BYTES=2000000000 # Amazon Transcribe accepts files up to 2 GB
readonly UNIT_PRICE=0.006     # USD per minute; the price page's us-east-1 batch example
readonly EXTENSIONS='mp3 mp4 m4a wav flac ogg webm amr'
readonly POLL_SECONDS=5
readonly WAIT_BASE_SECONDS=900 # the wait limit is this plus the audio duration
readonly DEFAULT_SPEAKERS=10
readonly KEY_PREFIX='transcribe-skill'

die() {
  printf 'transcribe: %s\n' "$1" >&2
  exit "${2:-2}"
}

warn() { printf 'transcribe: WARNING: %s\n' "$1" >&2; }

# ---- plugin settings ----
load_config() {
  [ -n "$T_KEY_ID" ] || die 'TRANSCRIBE_AWS_ACCESS_KEY_ID is not set (run the setup skill for the steps)'
  [ -n "$T_SECRET" ] || die 'TRANSCRIBE_AWS_SECRET_ACCESS_KEY is not set (run the setup skill for the steps)'
  [ -n "$T_REGION" ] || die 'TRANSCRIBE_AWS_REGION is not set (run the setup skill for the steps)'
  [ -n "$T_BUCKET" ] || die 'TRANSCRIBE_S3_BUCKET is not set (run the setup skill for the steps)'
  [ "${#T_KEY_ID}" -eq 20 ] || die 'TRANSCRIBE_AWS_ACCESS_KEY_ID must be 20 characters'
  [ "${#T_SECRET}" -eq 40 ] || die 'TRANSCRIBE_AWS_SECRET_ACCESS_KEY must be 40 characters'
  [[ $T_KEY_ID =~ ^[A-Z0-9]{20}$ ]] || die 'TRANSCRIBE_AWS_ACCESS_KEY_ID has characters an access key ID does not have'
  [[ $T_REGION =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || die 'TRANSCRIBE_AWS_REGION is not a region name such as ap-northeast-1'
  [[ $T_BUCKET =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die 'TRANSCRIBE_S3_BUCKET is not a bucket name (give the name only, without s3://)'
  case "$T_BUCKET" in *..*) die 'TRANSCRIBE_S3_BUCKET is not a bucket name (two dots in a row)' ;; esac
}

setup_aws_env() {
  export AWS_ACCESS_KEY_ID="$T_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$T_SECRET"
  export AWS_DEFAULT_REGION="$T_REGION"
  export AWS_CONFIG_FILE=/dev/null
  export AWS_SHARED_CREDENTIALS_FILE=/dev/null
  export AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true
  export AWS_EC2_METADATA_DISABLED=true
  export AWS_PAGER=''
}

aws_call() { aws --region "$T_REGION" "$@"; }

# ---- input ----
# validate_input <file>: sets INPUT, INPUT_BYTES, INPUT_SECONDS, OUT_DIR, OUT_JSON, OUT_TXT.
validate_input() {
  local f="${1-}" dir base ext e ok bytes secs name
  [ -n "$f" ] || die 'no file given'
  case "$f" in
    *$'\n'* | *$'\r'*) die 'the path contains a line break' ;;
  esac
  [ -L "$f" ] && die "the file is a symbolic link; give the real file: $f"
  [ -e "$f" ] || die "no such file: $f"
  [ -f "$f" ] || die "not a regular file: $f"

  dir=$(cd -P "$(dirname "$f")" 2> /dev/null && pwd) || die "cannot open the directory of: $f"
  base=$(basename "$f")
  INPUT="$dir/$base"

  ext=$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')
  ok=0
  [ "$base" != "$ext" ] && for e in $EXTENSIONS; do
    [ "$ext" = "$e" ] && ok=1
  done
  [ "$ok" -eq 1 ] || die "extension not allowed (allowed: $EXTENSIONS): $base"
  INPUT_EXT=$ext

  bytes=$(wc -c < "$INPUT" | tr -d ' ')
  [ "$bytes" -gt 0 ] || die "the file is empty: $base"
  [ "$bytes" -le "$MAX_BYTES" ] || die "the file is over the size limit of $MAX_BYTES bytes: $bytes bytes"
  INPUT_BYTES=$bytes

  command -v ffprobe > /dev/null 2>&1 || die 'ffprobe is required to measure the duration (it ships with ffmpeg)'
  secs=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -i "$INPUT" 2> /dev/null | head -n 1)
  case "$secs" in
    '' | *[!0-9.]* | *.*.*) die 'could not read a duration from the file' ;;
  esac
  awk -v d="$secs" 'BEGIN { exit !(d > 0) }' || die 'the duration is zero'
  awk -v d="$secs" -v m="$MAX_SECONDS" 'BEGIN { exit !(d <= m) }' \
    || die "the duration is over the limit of $((MAX_SECONDS / 60)) minutes"
  INPUT_SECONDS=$secs

  name=${base%.*}
  OUT_DIR=$dir
  OUT_JSON="$dir/$name.transcript.json"
  OUT_TXT="$dir/$name.transcript.txt"
}

refuse_existing_outputs() {
  [ ! -e "$OUT_JSON" ] || die "the output already exists, not overwriting: $OUT_JSON"
  [ ! -e "$OUT_TXT" ] || die "the output already exists, not overwriting: $OUT_TXT"
}

# git_unignored <path>: true when the path is inside a git work tree and git does not ignore it.
git_unignored() {
  command -v git > /dev/null 2>&1 || return 1
  git -C "$(dirname "$1")" rev-parse --is-inside-work-tree > /dev/null 2>&1 || return 1
  git -C "$(dirname "$1")" check-ignore -q -- "$1" && return 1
  return 0
}

# ---- estimate ----
cmd_estimate() {
  local git_flag=no
  validate_input "${1-}"
  if git_unignored "$OUT_JSON" || git_unignored "$OUT_TXT"; then git_flag=yes; fi
  awk -v d="$INPUT_SECONDS" -v p="$UNIT_PRICE" -v b="$INPUT_BYTES" -v f="$INPUT" -v lm="$((MAX_SECONDS / 60))" -v lb="$MAX_BYTES" \
    -v oj="$OUT_JSON" -v ot="$OUT_TXT" -v g="$git_flag" 'BEGIN {
    printf "file=%s\n", f
    printf "size_bytes=%d\n", b
    printf "duration_seconds=%d\n", d + 0.5
    printf "estimated_cost_usd=%.3f\n", d / 60 * p
    printf "unit_price_usd_per_minute=%s\n", p
    printf "price_basis=estimate from the Amazon Transcribe price page batch example for us-east-1; the price for your region may differ\n"
    printf "limit_duration_minutes=%d\n", lm
    printf "limit_size_bytes=%d\n", lb
    printf "output_json=%s\n", oj
    printf "output_text=%s\n", ot
    printf "output_in_unignored_git_worktree=%s\n", g
  }'
}

# ---- run ----
CLEANUP_NEEDED=0
JOB_CREATED=0
LEFT=''
TMP_JSON=''
TMP_TXT=''
ACCOUNT=''
IN_KEY=''
OUT_KEY=''
JOB=''

cleanup_aws() {
  [ "$CLEANUP_NEEDED" -eq 1 ] || return 0
  CLEANUP_NEEDED=0
  if [ "$JOB_CREATED" -eq 1 ]; then
    aws_call transcribe delete-transcription-job --transcription-job-name "$JOB" > /dev/null 2>&1 \
      || LEFT="$LEFT transcription-job:$JOB"
  fi
  aws_call s3api delete-object --bucket "$T_BUCKET" --key "$IN_KEY" --expected-bucket-owner "$ACCOUNT" > /dev/null 2>&1 \
    || LEFT="$LEFT s3://$T_BUCKET/$IN_KEY"
  aws_call s3api delete-object --bucket "$T_BUCKET" --key "$OUT_KEY" --expected-bucket-owner "$ACCOUNT" > /dev/null 2>&1 \
    || LEFT="$LEFT s3://$T_BUCKET/$OUT_KEY"
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  cleanup_aws
  [ -n "$TMP_JSON" ] && rm -f "$TMP_JSON"
  [ -n "$TMP_TXT" ] && rm -f "$TMP_TXT"
  if [ -n "$LEFT" ]; then
    warn "could not delete from AWS; delete by hand (the bucket's lifecycle rule removes objects after a day):$LEFT"
    [ "$rc" -eq 0 ] && rc=3
  fi
  exit "$rc"
}

wait_for_job() {
  local polls=0 max status reason
  max=$(((WAIT_BASE_SECONDS + ${INPUT_SECONDS%.*}) / POLL_SECONDS))
  while [ "$polls" -lt "$max" ]; do
    status=$(aws_call transcribe get-transcription-job --transcription-job-name "$JOB" \
      --query 'TranscriptionJob.TranscriptionJobStatus' --output text) || die 'could not read the job status' 1
    case "$status" in
      COMPLETED) return 0 ;;
      FAILED)
        reason=$(aws_call transcribe get-transcription-job --transcription-job-name "$JOB" \
          --query 'TranscriptionJob.FailureReason' --output text 2> /dev/null)
        die "the job failed: $reason" 1
        ;;
      QUEUED | IN_PROGRESS)
        polls=$((polls + 1))
        sleep "$POLL_SECONDS"
        ;;
      *) die "unexpected job status: $status" 1 ;;
    esac
  done
  die "the job did not finish within $((max * POLL_SECONDS)) seconds" 1
}

# One line per speaker turn: [MM:SS spk_N] text. Without speaker labels, the plain transcript.
read -r -d '' FORMAT_JQ <<'JQ'
def pad2: tostring | if length < 2 then "0" + . else . end;
def stamp: floor as $s | (($s / 60 | floor) | pad2) + ":" + (($s % 60) | pad2);
.results as $r
| ($r.speaker_labels.segments // []) as $segs
| if ($segs | length) == 0 then ($r.transcripts[0].transcript // "")
  else
    ( $r.items
      | reduce .[] as $it ({label: null, rows: []};
          if $it.type == "punctuation" then
            .rows += [{label: .label, start: null, text: $it.alternatives[0].content}]
          else
            ($it.start_time | tonumber) as $s
            | ([$segs[] | select((.start_time | tonumber) <= $s and $s <= (.end_time | tonumber))] | first) as $seg
            | (if $seg then $seg.speaker_label else .label end) as $lab
            | .label = $lab
            | .rows += [{label: $lab, start: $s, text: $it.alternatives[0].content}]
          end)
      | .rows
      | reduce .[] as $row ([];
          if length > 0 and .[length - 1].label == $row.label then
            (length - 1) as $i | .[$i].text += $row.text
          else
            . + [{label: $row.label, start: $row.start, text: $row.text}]
          end)
      | .[]
      | "[" + ((.start // 0) | stamp) + " " + (.label // "spk_?") + "] " + .text )
  end
JQ

cmd_run() {
  local file='' speakers=$DEFAULT_SPEAKERS rid prefix out_prefix
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-speakers)
        [ $# -ge 2 ] || die '--max-speakers needs a number'
        speakers=$2
        shift 2
        ;;
      --*) die "unknown option: $1" ;;
      *)
        [ -z "$file" ] || die 'only one file can be given'
        file=$1
        shift
        ;;
    esac
  done
  case "$speakers" in
    '' | *[!0-9]*) die '--max-speakers must be a whole number from 2 to 30' ;;
  esac
  { [ "$speakers" -ge 2 ] && [ "$speakers" -le 30 ]; } || die '--max-speakers must be a whole number from 2 to 30'

  load_config
  command -v jq > /dev/null 2>&1 || die 'jq is required to build the text transcript'
  validate_input "$file"
  refuse_existing_outputs
  setup_aws_env

  ACCOUNT=$(aws_call sts get-caller-identity --query Account --output text) || die 'could not read the AWS account for these keys' 1
  [[ $ACCOUNT =~ ^[0-9]{12}$ ]] || die 'the AWS account ID has an unexpected shape' 1

  rid=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [[ $rid =~ ^[0-9a-f]{16}$ ]] || die 'could not make a random ID' 1
  prefix="$KEY_PREFIX/$rid"
  out_prefix="$prefix/out/"
  JOB="tsk-$rid"
  IN_KEY="$prefix/in/audio.$INPUT_EXT"
  OUT_KEY="$out_prefix$JOB.json"

  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  # Made before the upload so an unwritable directory fails before any AWS call.
  TMP_JSON=$(mktemp "$OUT_DIR/.transcribe.XXXXXX") || die "cannot write in the output directory: $OUT_DIR"
  TMP_TXT=$(mktemp "$OUT_DIR/.transcribe.XXXXXX") || die "cannot write in the output directory: $OUT_DIR"

  CLEANUP_NEEDED=1
  aws_call s3api put-object --bucket "$T_BUCKET" --key "$IN_KEY" --body "$INPUT" \
    --expected-bucket-owner "$ACCOUNT" > /dev/null || die 'the upload failed' 1

  aws_call transcribe start-transcription-job --transcription-job-name "$JOB" \
    --language-code ja-JP --media "MediaFileUri=s3://$T_BUCKET/$IN_KEY" \
    --output-bucket-name "$T_BUCKET" --output-key "$out_prefix" \
    --settings "ShowSpeakerLabels=true,MaxSpeakerLabels=$speakers" \
    --query 'TranscriptionJob.TranscriptionJobStatus' --output text > /dev/null || die 'could not start the job' 1
  JOB_CREATED=1

  wait_for_job

  aws_call s3api get-object --bucket "$T_BUCKET" --key "$OUT_KEY" \
    --expected-bucket-owner "$ACCOUNT" "$TMP_JSON" > /dev/null || die 'could not download the result' 1
  jq -e '.results.items' "$TMP_JSON" > /dev/null 2>&1 || die 'the result is not a Transcribe result' 1
  jq -r "$FORMAT_JQ" "$TMP_JSON" > "$TMP_TXT" || die 'could not build the text transcript' 1

  refuse_existing_outputs
  chmod 600 "$TMP_JSON" "$TMP_TXT"
  mv "$TMP_JSON" "$OUT_JSON" || die 'could not write the json output' 1
  TMP_JSON=''
  mv "$TMP_TXT" "$OUT_TXT" || die 'could not write the text output' 1
  TMP_TXT=''

  printf 'transcript_json=%s\n' "$OUT_JSON"
  printf 'transcript_text=%s\n' "$OUT_TXT"
  if git_unignored "$OUT_JSON" || git_unignored "$OUT_TXT"; then
    warn "the output is inside a git work tree and git does not ignore it; add the files to .gitignore or move them before you commit: $OUT_DIR"
  fi
  exit 0
}

sub="${1-}"
[ $# -gt 0 ] && shift
case "$sub" in
  estimate) cmd_estimate "$@" ;;
  run) cmd_run "$@" ;;
  '') die 'usage: transcribe.sh estimate <file> | run <file> [--max-speakers N]' ;;
  *) die "unknown subcommand: $sub" ;;
esac
