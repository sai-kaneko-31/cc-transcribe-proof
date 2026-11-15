#!/usr/bin/env bash
# Wrapper around the AWS CLI for the transcribe plugin.
#
#   transcribe.sh estimate <file>   check the file, print duration and cost estimate (no AWS call)
#
# Exit codes: 0 ok, 1 an AWS call or the job failed, 2 bad input or setup.
# Written for bash 3.2 (the macOS default), so no associative arrays or mapfile.
set -u
set -o pipefail

# ---- limits (constants; deliberately not overridable from the environment) ----
readonly MAX_SECONDS=7200            # 120 minutes: keeps one transcript small enough for the corrector
readonly MAX_BYTES=2000000000        # Amazon Transcribe accepts files up to 2 GB
readonly UNIT_PRICE=0.006            # USD per minute; the price page's us-east-1 batch example
readonly EXTENSIONS='mp3 mp4 m4a wav flac ogg webm amr'

die() {
  printf 'transcribe: %s\n' "$1" >&2
  exit "${2:-2}"
}

# validate_input <file>: sets INPUT (absolute path), INPUT_BYTES, INPUT_SECONDS.
validate_input() {
  local f="${1-}" dir base ext e ok bytes secs
  [ -n "$f" ] || die 'no file given. usage: transcribe.sh estimate <file>'
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
}

cmd_estimate() {
  validate_input "${1-}"
  awk -v d="$INPUT_SECONDS" -v p="$UNIT_PRICE" -v b="$INPUT_BYTES" -v f="$INPUT" -v lm="$((MAX_SECONDS / 60))" -v lb="$MAX_BYTES" 'BEGIN {
    printf "file=%s\n", f
    printf "size_bytes=%d\n", b
    printf "duration_seconds=%d\n", d + 0.5
    printf "estimated_cost_usd=%.3f\n", d / 60 * p
    printf "unit_price_usd_per_minute=%s\n", p
    printf "price_basis=estimate from the Amazon Transcribe price page batch example for us-east-1; the price for your region may differ\n"
    printf "limit_duration_minutes=%d\n", lm
    printf "limit_size_bytes=%d\n", lb
  }'
}

sub="${1-}"
[ $# -gt 0 ] && shift
case "$sub" in
  estimate) cmd_estimate "$@" ;;
  '') die 'usage: transcribe.sh estimate <file>' ;;
  *) die "unknown subcommand: $sub" ;;
esac
