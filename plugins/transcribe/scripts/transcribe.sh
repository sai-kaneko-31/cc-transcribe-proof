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
# config_problem: prints the first problem with the plugin's settings, or nothing.
# Messages name the variable and never contain its value.
config_problem() {
  [ -n "$T_KEY_ID" ] || { echo 'TRANSCRIBE_AWS_ACCESS_KEY_ID is not set (run the setup skill for the steps)'; return; }
  [ -n "$T_SECRET" ] || { echo 'TRANSCRIBE_AWS_SECRET_ACCESS_KEY is not set (run the setup skill for the steps)'; return; }
  [ -n "$T_REGION" ] || { echo 'TRANSCRIBE_AWS_REGION is not set (run the setup skill for the steps)'; return; }
  [ -n "$T_BUCKET" ] || { echo 'TRANSCRIBE_S3_BUCKET is not set (run the setup skill for the steps)'; return; }
  [ "${#T_KEY_ID}" -eq 20 ] || { echo 'TRANSCRIBE_AWS_ACCESS_KEY_ID must be 20 characters'; return; }
  [ "${#T_SECRET}" -eq 40 ] || { echo 'TRANSCRIBE_AWS_SECRET_ACCESS_KEY must be 40 characters'; return; }
  [[ $T_KEY_ID =~ ^[A-Z0-9]{20}$ ]] || { echo 'TRANSCRIBE_AWS_ACCESS_KEY_ID has characters an access key ID does not have'; return; }
  [[ $T_REGION =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || { echo 'TRANSCRIBE_AWS_REGION is not a region name such as ap-northeast-1'; return; }
  [[ $T_BUCKET =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { echo 'TRANSCRIBE_S3_BUCKET is not a bucket name (give the name only, without s3://)'; return; }
  case "$T_BUCKET" in *..*) echo 'TRANSCRIBE_S3_BUCKET is not a bucket name (two dots in a row)' ;; esac
}

load_config() {
  local problem
  problem=$(config_problem)
  [ -z "$problem" ] || die "$problem"
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

# ---- verify ----
VERIFY_FAILED=0

# check_ok / check_ng are called directly (never inside a command substitution),
# so VERIFY_FAILED survives.
check_ok() { printf 'check %s: ok%s\n' "$1" "${2:+ ($2)}"; }
check_ng() {
  printf 'check %s: NG %s\n' "$1" "$2"
  VERIFY_FAILED=1
}

is_denied() { printf '%s' "$1" | grep -q 'AccessDenied'; }

# Checks the setup end to end without sending any audio: the settings, who the
# key belongs to, that the key is not broader than the plugin policy, bucket
# access inside and outside the prefix, and the three Transcribe operations.
# The Transcribe operations are tried on a text file posing as audio, which
# makes a job that fails in seconds.
cmd_verify() {
  local problem arn rid prefix probe_key outside_key out rc polls status get_ok bucket_ok
  problem=$(config_problem)
  if [ -n "$problem" ]; then
    check_ng env "$problem"
    printf 'result=ng\n'
    exit 2
  fi
  check_ok env
  setup_aws_env

  if ! ACCOUNT=$(aws_call sts get-caller-identity --query Account --output text 2> /dev/null) \
    || ! [[ $ACCOUNT =~ ^[0-9]{12}$ ]] \
    || ! arn=$(aws_call sts get-caller-identity --query Arn --output text 2> /dev/null); then
    check_ng identity 'could not read the identity for these keys (wrong keys, wrong region setting, or no network)'
    printf 'result=ng\n'
    exit 1
  fi
  case "$arn" in
    *:root) check_ng identity 'these are root user keys; create an IAM user for the plugin' ;;
    *) check_ok identity "user ${arn##*/}" ;;
  esac

  rid=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [[ $rid =~ ^[0-9a-f]{16}$ ]] || die 'could not make a random ID' 1
  prefix="$KEY_PREFIX/$rid"
  probe_key="$prefix/verify/probe.txt"
  outside_key="verify-outside-$rid.txt"
  JOB="tsk-$rid"
  IN_KEY="$prefix/probe/audio.wav"
  OUT_KEY="$prefix/out/$JOB.json"

  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  TMP_TXT=$(mktemp) || die 'cannot make a temporary file'
  TMP_JSON=$(mktemp) || die 'cannot make a temporary file'
  CLEANUP_NEEDED=1

  # A key that can list IAM users is broader than the plugin policy.
  out=$(aws_call iam list-users --max-items 1 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    check_ng broad-key 'this key can list IAM users, so it is broader than the plugin policy; use a key limited to the plugin policy'
  elif is_denied "$out"; then
    check_ok broad-key 'iam:ListUsers is denied'
  else
    check_ng broad-key 'could not tell whether the key is broad (unexpected error from AWS)'
  fi

  bucket_ok=1
  printf 'verify-%s\n' "$rid" > "$TMP_TXT"
  aws_call s3api put-object --bucket "$T_BUCKET" --key "$probe_key" --body "$TMP_TXT" \
    --expected-bucket-owner "$ACCOUNT" > /dev/null 2>&1 || bucket_ok=0
  if [ "$bucket_ok" -eq 1 ]; then
    aws_call s3api get-object --bucket "$T_BUCKET" --key "$probe_key" \
      --expected-bucket-owner "$ACCOUNT" "$TMP_JSON" > /dev/null 2>&1 || bucket_ok=0
    cmp -s "$TMP_JSON" "$TMP_TXT" || bucket_ok=0
    aws_call s3api delete-object --bucket "$T_BUCKET" --key "$probe_key" \
      --expected-bucket-owner "$ACCOUNT" > /dev/null 2>&1 || bucket_ok=0
  fi
  if [ "$bucket_ok" -eq 1 ]; then
    check_ok bucket-rw "put, get and delete work under $KEY_PREFIX/"
  else
    check_ng bucket-rw "put, get or delete under $KEY_PREFIX/ failed; check the bucket name, the region and the Objects statement of the policy"
  fi

  out=$(aws_call s3api put-object --bucket "$T_BUCKET" --key "$outside_key" --body "$TMP_TXT" \
    --expected-bucket-owner "$ACCOUNT" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    aws_call s3api delete-object --bucket "$T_BUCKET" --key "$outside_key" \
      --expected-bucket-owner "$ACCOUNT" > /dev/null 2>&1
    check_ng bucket-outside-prefix "the key can write outside $KEY_PREFIX/; narrow the policy to the prefix"
  elif is_denied "$out"; then
    check_ok bucket-outside-prefix "a write outside $KEY_PREFIX/ is denied"
  else
    check_ng bucket-outside-prefix 'could not tell (unexpected error from AWS)'
  fi

  out=$(aws_call s3api list-objects-v2 --bucket "$T_BUCKET" --max-keys 1 --expected-bucket-owner "$ACCOUNT" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    check_ng bucket-list 'the key can list the bucket; remove s3:ListBucket from the policy'
  elif is_denied "$out"; then
    check_ok bucket-list 'listing the bucket is denied'
  else
    check_ng bucket-list 'could not tell (unexpected error from AWS)'
  fi

  printf 'this is not audio\n' > "$TMP_TXT"
  if ! aws_call s3api put-object --bucket "$T_BUCKET" --key "$IN_KEY" --body "$TMP_TXT" \
    --expected-bucket-owner "$ACCOUNT" > /dev/null 2>&1; then
    check_ng transcribe-start 'skipped: the probe upload failed'
    check_ng transcribe-get 'skipped: the probe job did not start'
    check_ng transcribe-delete 'skipped: the probe job did not start'
  elif ! aws_call transcribe start-transcription-job --transcription-job-name "$JOB" \
    --language-code ja-JP --media "MediaFileUri=s3://$T_BUCKET/$IN_KEY" \
    --output-bucket-name "$T_BUCKET" --output-key "$prefix/out/" \
    --query 'TranscriptionJob.TranscriptionJobStatus' --output text > /dev/null 2>&1; then
    check_ng transcribe-start 'could not start a job; check transcribe:StartTranscriptionJob in the policy'
    check_ng transcribe-get 'skipped: the probe job did not start'
    check_ng transcribe-delete 'skipped: the probe job did not start'
  else
    JOB_CREATED=1
    check_ok transcribe-start 'a job was created; it is expected to end FAILED because the file is not audio'
    get_ok=0
    polls=0
    while [ "$polls" -lt 12 ]; do
      if status=$(aws_call transcribe get-transcription-job --transcription-job-name "$JOB" \
        --query 'TranscriptionJob.TranscriptionJobStatus' --output text 2> /dev/null); then
        get_ok=1
        case "$status" in
          QUEUED | IN_PROGRESS)
            polls=$((polls + 1))
            sleep "$POLL_SECONDS"
            ;;
          *) break ;;
        esac
      else
        break
      fi
    done
    if [ "$get_ok" -eq 1 ]; then
      check_ok transcribe-get 'the job status can be read'
    else
      check_ng transcribe-get 'could not read the job; check transcribe:GetTranscriptionJob in the policy'
    fi
    if aws_call transcribe delete-transcription-job --transcription-job-name "$JOB" > /dev/null 2>&1; then
      JOB_CREATED=0
      check_ok transcribe-delete 'the probe job was deleted'
    else
      check_ng transcribe-delete "could not delete the probe job $JOB; check transcribe:DeleteTranscriptionJob in the policy and delete the job by hand"
    fi
  fi

  if [ "$VERIFY_FAILED" -eq 0 ]; then printf 'result=ok\n'; else printf 'result=ng\n'; fi
  exit "$VERIFY_FAILED"
}

# ---- apply ----
readonly MAX_TEXT_BYTES=2000000

# Applies the corrector's edits to a transcript. The corrector can only Read, so
# it returns edits as data; this program is the only thing that changes text.
# An edit is applied only when it is well formed and its "old" text occurs
# exactly once in the line; speaker labels are never touched; "new" cannot be
# much longer than "old", so no new sentences can be slipped in.
read -r -d '' APPLY_JQ <<'JQ'
def prefix_of: capture("^(?<p>\\[[0-9]+:[0-9]{2} [^\\]]*\\] )?(?<b>.*)$");
def line_ok($max): type == "number" and . == floor and . >= 1 and . <= $max;
def reason_for($max):
  if type != "object" then "the edit is not an object"
  elif (.line | line_ok($max) | not) then "line is not a whole number within the transcript"
  elif ((.old | type) != "string") or ((.new | type) != "string") then "old and new must be strings"
  elif ((.reason | type) != "string") or (.reason == "") then "reason is missing"
  elif (.confidence != "high" and .confidence != "medium") then "confidence must be high or medium (low confidence belongs in flags)"
  elif .old == "" then "old is empty"
  elif .old == .new then "old and new are the same"
  elif (.old | test("\n")) or (.new | test("\n")) then "old or new has a line break"
  elif (.new | length) > ((.old | length) * 3 + 20) then "new is too long compared with old"
  else null end;
[inputs] as $lines
| $e[0] as $edits
| ($lines | length) as $max
| reduce ($edits.edits | to_entries[]) as $entry ({lines: $lines, applied: [], rejected: [], flags: []};
    $entry.value as $x
    | ($x | reason_for($max)) as $why
    | if $why then .rejected += [{edit: $x, reason: $why}]
      else
        (.lines[$x.line - 1] | prefix_of) as $l
        | (($l.b | split($x.old) | length) - 1) as $count
        | if $count != 1 then
            .rejected += [{edit: $x, reason: "old text not found exactly once in the line (found \($count) times)"}]
          else
            .lines[$x.line - 1] = (($l.p // "") + ($l.b | split($x.old) | join($x.new)))
            | .applied += [$x]
          end
      end)
| reduce $edits.flags[] as $f (.;
    if ($f | type) == "object" and ($f.line | line_ok($max)) and (($f.text | type) == "string") and (($f.reason | type) == "string")
    then .flags += [{line: $f.line, text: $f.text[0:200], reason: $f.reason[0:200]}]
    else .rejected += [{flag: $f, reason: "the flag is malformed or its line is out of range"}]
    end)
JQ

cmd_apply() {
  local transcript="${1-}" editsfile="${2-}" f bytes dir base name out_corrected out_corrections result
  [ -n "$transcript" ] && [ -n "$editsfile" ] || die 'usage: transcribe.sh apply <transcript.txt> <edits.json>'
  command -v jq > /dev/null 2>&1 || die 'jq is required to apply the edits'
  for f in "$transcript" "$editsfile"; do
    [ -L "$f" ] && die "a symbolic link is not accepted: $f"
    [ -f "$f" ] || die "no such file: $f"
    bytes=$(wc -c < "$f" | tr -d ' ')
    [ "$bytes" -le "$MAX_TEXT_BYTES" ] || die "the file is over $MAX_TEXT_BYTES bytes: $f"
  done
  jq -e 'type == "object" and (.edits | type) == "array" and (.flags | type) == "array"' "$editsfile" > /dev/null 2>&1 \
    || die 'the edit file must be a JSON object with an "edits" array and a "flags" array'

  dir=$(cd -P "$(dirname "$transcript")" 2> /dev/null && pwd) || die "cannot open the directory of: $transcript"
  base=$(basename "$transcript")
  case "$base" in
    *.transcript.txt) name=${base%.transcript.txt} ;;
    *.txt) name=${base%.txt} ;;
    *) name=$base ;;
  esac
  out_corrected="$dir/$name.corrected.txt"
  out_corrections="$dir/$name.corrections.json"
  [ ! -e "$out_corrected" ] || die "the output already exists, not overwriting: $out_corrected"
  [ ! -e "$out_corrections" ] || die "the output already exists, not overwriting: $out_corrections"

  trap on_exit EXIT
  TMP_TXT=$(mktemp "$dir/.transcribe.XXXXXX") || die "cannot write in the directory: $dir"
  TMP_JSON=$(mktemp "$dir/.transcribe.XXXXXX") || die "cannot write in the directory: $dir"

  result=$(jq -R -n --slurpfile e "$editsfile" "$APPLY_JQ" "$transcript") || die 'could not apply the edits' 1
  printf '%s' "$result" | jq -r '.lines[]' > "$TMP_TXT" || die 'could not write the corrected text' 1
  printf '%s' "$result" | jq '{applied, rejected, flags}' > "$TMP_JSON" || die 'could not write the corrections' 1
  chmod 600 "$TMP_TXT" "$TMP_JSON"
  mv "$TMP_TXT" "$out_corrected" || die 'could not write the corrected text' 1
  TMP_TXT=''
  mv "$TMP_JSON" "$out_corrections" || die 'could not write the corrections' 1
  TMP_JSON=''

  printf 'corrected_text=%s\n' "$out_corrected"
  printf 'corrections_json=%s\n' "$out_corrections"
  printf '%s' "$result" | jq -r '
    "applied=\(.applied | length)",
    "rejected=\(.rejected | length)",
    "flagged=\(.flags | length)",
    (.applied[] | "edit line \(.line): \(.old) -> \(.new) (\(.confidence): \(.reason))"),
    (.rejected[] | "rejected: \(.reason): \((.edit // .flag) | tojson | .[0:160])"),
    (.flags[] | "flag line \(.line): \(.text) (\(.reason))")'
  exit 0
}

sub="${1-}"
[ $# -gt 0 ] && shift
case "$sub" in
  estimate) cmd_estimate "$@" ;;
  run) cmd_run "$@" ;;
  verify) cmd_verify "$@" ;;
  apply) cmd_apply "$@" ;;
  '') die 'usage: transcribe.sh estimate <file> | run <file> [--max-speakers N] | verify | apply <transcript.txt> <edits.json>' ;;
  *) die "unknown subcommand: $sub" ;;
esac
