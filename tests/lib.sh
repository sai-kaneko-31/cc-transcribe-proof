#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034
# (the sandbox variables are set in make_sandbox and used by the sourcing test)
#
# Shared helpers for tests/test_*.sh. Source this file; do not run it.
#
# Every test runs the wrapper against a fake `aws`, `ffprobe` and `sleep` that
# sit first on PATH. The fake `aws` is generated here with its state directory
# written into the script, so no test-only environment variable has to survive
# the wrapper's environment scrub.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wrapper="$root/plugins/transcribe-proof/scripts/transcribe.sh"

pass=0
fail=0

# make_sandbox: creates $sb (scratch dir), $fakebin, $state and the fakes.
make_sandbox() {
  sb=$(cd -P "$(mktemp -d)" && pwd) # resolved: the wrapper prints real paths (/var is /private/var on macOS)
  fakebin="$sb/fakebin"
  state="$sb/state"
  mkdir -p "$fakebin" "$state" "$sb/media"
  printf '60\n' > "$state/duration" # seconds; the fake ffprobe prints this
  printf 'COMPLETED\n' > "$state/status-seq"

  cat > "$fakebin/ffprobe" <<'FAKE'
#!/usr/bin/env bash
state='__STATE__'
[ -e "$state/ffprobe-fail" ] && { echo 'ffprobe: failed' >&2; exit 1; }
[ -e "$state/ffprobe-garbage" ] && { echo 'N/A'; exit 0; }
cat "$state/duration"
FAKE

  cat > "$fakebin/sleep" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

  cat > "$fakebin/aws" <<'FAKE'
#!/usr/bin/env bash
state='__STATE__'
# argval <option> <args...>: the value that follows the option.
argval() {
  local want="$1"
  shift
  while [ $# -gt 1 ]; do
    [ "$1" = "$want" ] && { echo "$2"; return; }
    shift
  done
}
# hang <name>: while $state/hang-<name> exists, wait (and say so in $state/hanging) until $state/release exists.
hang() {
  [ -e "$state/hang-$1" ] || return 0
  : > "$state/hanging"
  while [ ! -e "$state/release" ]; do /bin/sleep 0.05; done
}
n=$(ls "$state" | grep -c '^env-')
env | sort > "$state/env-$n.txt"
{
  printf 'ARGV'
  for a in "$@"; do printf ' [%s]' "$a"; done
  printf '\n'
} >> "$state/calls.log"
[ "$1" = '--region' ] && shift 2
op="$1 $2"
if [ -e "$state/fail-$2" ]; then
  echo "An error occurred (AccessDenied) when calling the $2 operation: fake denial" >&2
  exit 254
fi
args="$*"
case "$op" in
  'sts get-caller-identity')
    case "$args" in
      *Account*) echo '123456789012' ;;
      *Arn*)
        if [ -e "$state/root-arn" ]; then echo 'arn:aws:iam::123456789012:root'; else
          echo 'arn:aws:iam::123456789012:user/fake-transcribe-user'
        fi
        ;;
      *) echo '{"Account":"123456789012"}' ;;
    esac
    ;;
  'iam list-users')
    if [ -e "$state/broad-key" ]; then echo '{"Users":[]}'; else
      echo 'An error occurred (AccessDenied) when calling the ListUsers operation: fake denial' >&2
      exit 254
    fi
    ;;
  's3api put-object')
    key=$(argval --key "$@")
    case "$key" in
      transcribe-skill/*) ;;
      *)
        # like the shipped policy: only the plugin's prefix is writable
        [ -e "$state/allow-outside-put" ] || {
          echo 'An error occurred (AccessDenied) when calling the PutObject operation: fake denial' >&2
          exit 254
        }
        ;;
    esac
    mkdir -p "$state/obj"
    cp "$(argval --body "$@")" "$state/obj/$(printf '%s' "$key" | tr '/' '_')"
    case "$args" in
      *VersionId*) if [ -e "$state/versioned" ]; then echo 'fakeversion1'; else echo 'None'; fi ;;
      *) echo '{"ETag":"fake"}' ;;
    esac
    ;;
  's3api get-object')
    for last in "$@"; do :; done
    saved="$state/obj/$(printf '%s' "$(argval --key "$@")" | tr '/' '_')"
    if [ -e "$saved" ]; then
      cp "$saved" "$last"
    elif [ -e "$state/result.json" ]; then
      cp "$state/result.json" "$last"
    else
      echo 'no such key' >&2
      exit 254
    fi
    [ -e "$state/corrupt-get" ] && printf 'corrupted\n' > "$last"
    echo '{}'
    ;;
  's3api delete-object')
    if [ -e "$state/versioned" ]; then
      case "$args" in *DeleteMarker*) echo 'True' ;; esac
    else
      rm -f "$state/obj/$(printf '%s' "$(argval --key "$@")" | tr '/' '_')"
      case "$args" in *DeleteMarker*) echo 'None' ;; esac
    fi
    ;;
  's3api list-objects-v2')
    if [ -e "$state/allow-list" ]; then echo '{"Contents":[]}'; else
      echo 'An error occurred (AccessDenied) when calling the ListObjectsV2 operation: fake denial' >&2
      exit 254
    fi
    ;;
  'transcribe start-transcription-job')
    hang start
    # Amazon Transcribe leaves an empty check file under the output key (seen against real AWS)
    mkdir -p "$state/obj"
    : > "$state/obj/$(printf '%s' "$(argval --output-key "$@").write_access_check_file.temp" | tr '/' '_')"
    echo 'IN_PROGRESS'
    ;;
  'transcribe get-transcription-job')
    c=$(cat "$state/get-count" 2> /dev/null || echo 0)
    echo $((c + 1)) > "$state/get-count"
    s=$(sed -n "$((c + 1))p" "$state/status-seq")
    [ -n "$s" ] || s=$(tail -n 1 "$state/status-seq")
    case "$args" in
      *FailureReason*) cat "$state/failure-reason" 2> /dev/null || echo 'fake failure' ;;
      *) echo "$s" ;;
    esac
    ;;
  'transcribe delete-transcription-job') hang delete ;;
  *) echo "unexpected fake aws call: $op" >&2; exit 99 ;;
esac
FAKE

  local f
  for f in ffprobe sleep aws; do
    sed -i.bak "s|__STATE__|$state|" "$fakebin/$f" && rm -f "$fakebin/$f.bak"
    chmod +x "$fakebin/$f"
  done
}

cleanup_sandbox() { [ -n "${sb:-}" ] && rm -rf "$sb"; }

# media <name>: creates a small file under $sb/media and prints its path.
media() {
  printf 'not really audio\n' > "$sb/media/$1"
  printf '%s\n' "$sb/media/$1"
}

# run_wrapper <args...>: runs the wrapper with the fakes first on PATH.
# Sets $out (stdout and stderr together) and $code. Extra environment goes in
# the array $wenv (name=value items).
run_wrapper() {
  out=$(env PATH="$fakebin:$PATH" ${wenv[@]+"${wenv[@]}"} "$BASH" "$wrapper" "$@" 2>&1)
  code=$?
}

ok() {
  echo "ok   $1"
  pass=$((pass + 1))
}

bad() {
  echo "FAIL $1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'
  fail=$((fail + 1))
}

# expect_code <label> <want>: checks $code from the last run_wrapper.
expect_code() {
  if [ "$code" -eq "$2" ]; then ok "$1"; else bad "$1: exit $code, want $2" "$out"; fi
}

# expect_out <label> <needle>: checks that $out contains the fixed string.
expect_out() {
  if printf '%s' "$out" | grep -q -F -e "$2"; then ok "$1"; else bad "$1: output lacks '$2'" "$out"; fi
}

# expect_no_out <label> <needle>: checks that $out lacks the fixed string.
expect_no_out() {
  if printf '%s' "$out" | grep -q -F -e "$2"; then bad "$1: output has '$2'" "$out"; else ok "$1"; fi
}

# expect_calls <label> <count> <needle>: counts calls.log lines with the string.
expect_calls() {
  local got
  got=$(grep -c -F -e "$3" "$state/calls.log" 2> /dev/null)
  [ -n "$got" ] || got=0
  if [ "$got" -eq "$2" ]; then ok "$1"; else bad "$1: $got calls with '$3', want $2" "$(cat "$state/calls.log" 2> /dev/null)"; fi
}

# ---- helpers for tests that run the wrapper against the fake aws ----

# Credential-shaped strings are assembled at run time so none sits in the repository.
key_id="AKIA""FAKEFAKEFAKEFAKE"
secret=$(printf 'f%.0s' $(seq 1 40))
bucket='fake-bucket-name'

base_env() {
  wenv=("TRANSCRIBE_AWS_ACCESS_KEY_ID=$key_id" "TRANSCRIBE_AWS_SECRET_ACCESS_KEY=$secret"
    "TRANSCRIBE_AWS_REGION=ap-northeast-1" "TRANSCRIBE_S3_BUCKET=$bucket")
}

fresh() {
  rm -f "$state"/calls.log "$state"/env-*.txt "$state"/get-count "$state"/fail-* "$state"/broad-key "$state"/root-arn "$state"/corrupt-get "$state"/versioned "$state"/hang-* "$state"/hanging "$state"/release "$state"/allow-*
  rm -rf "$state/obj"
  rm -f "$sb"/media/*.transcript.*
  printf 'COMPLETED\n' > "$state/status-seq"
  cat > "$state/result.json" <<'JSON'
{"jobName":"x","accountId":"123456789012","results":{
 "transcripts":[{"transcript":"こんにちは。お願いします。はい。"}],
 "speaker_labels":{"speakers":2,"segments":[
  {"start_time":"0.0","end_time":"3.5","speaker_label":"spk_0","items":[]},
  {"start_time":"4.0","end_time":"6.0","speaker_label":"spk_1","items":[]},
  {"start_time":"65.0","end_time":"69.0","speaker_label":"spk_0","items":[]}]},
 "items":[
  {"start_time":"0.0","end_time":"3.5","type":"pronunciation","alternatives":[{"confidence":"0.9","content":"こんにちは"}]},
  {"type":"punctuation","alternatives":[{"confidence":"0.0","content":"。"}]},
  {"start_time":"4.0","end_time":"6.0","type":"pronunciation","alternatives":[{"confidence":"0.9","content":"お願いします"}]},
  {"type":"punctuation","alternatives":[{"confidence":"0.0","content":"。"}]},
  {"start_time":"65.0","end_time":"69.0","type":"pronunciation","alternatives":[{"confidence":"0.9","content":"はい"}]},
  {"type":"punctuation","alternatives":[{"confidence":"0.0","content":"。"}]}]}}
JSON
}

# call_line <op>: the calls.log lines for one operation name.
call_line() { grep -F -e "[$1]" "$state/calls.log" 2> /dev/null; }

# line_of <needle>: line number of the first calls.log line with the string (0 if none).
line_of() { grep -n -F -e "$1" "$state/calls.log" 2> /dev/null | head -n 1 | cut -d: -f1 | grep . || echo 0; }

# last_line_of <needle>
last_line_of() { grep -n -F -e "$1" "$state/calls.log" 2> /dev/null | tail -n 1 | cut -d: -f1 | grep . || echo 0; }

expect_call_has() { # label op needle
  if call_line "$2" | grep -q -F -e "$3"; then ok "$1"; else bad "$1: no $2 call with '$3'" "$(cat "$state/calls.log" 2> /dev/null)"; fi
}

expect_before() { # label needleA needleB: first A comes before first B
  local a b
  a=$(line_of "$2")
  b=$(line_of "$3")
  if [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]; then ok "$1"; else bad "$1: '$2' at $a, '$3' at $b" "$(cat "$state/calls.log" 2> /dev/null)"; fi
}

expect_file() { if [ -f "$2" ]; then ok "$1"; else bad "$1: no file $2"; fi; }
expect_no_file() { if [ -e "$2" ]; then bad "$1: found $2"; else ok "$1"; fi; }

finish() {
  echo "$pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
