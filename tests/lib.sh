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
wrapper="$root/plugins/transcribe/scripts/transcribe.sh"

pass=0
fail=0

# make_sandbox: creates $sb (scratch dir), $fakebin, $state and the fakes.
make_sandbox() {
  sb=$(mktemp -d)
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
n=$(ls "$state" | grep -c '^env-')
env | sort > "$state/env-$n.txt"
{
  printf 'ARGV'
  for a in "$@"; do printf ' [%s]' "$a"; done
  printf '\n'
} >> "$state/calls.log"
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
      *Arn*) echo 'arn:aws:iam::123456789012:user/fake-transcribe-user' ;;
      *) echo '{"Account":"123456789012"}' ;;
    esac
    ;;
  'iam list-users')
    if [ -e "$state/broad-key" ]; then echo '{"Users":[]}'; else
      echo 'An error occurred (AccessDenied) when calling the ListUsers operation: fake denial' >&2
      exit 254
    fi
    ;;
  's3api put-object') echo '{"ETag":"fake"}' ;;
  's3api get-object')
    for last in "$@"; do :; done
    [ -e "$state/result.json" ] || { echo 'no such key' >&2; exit 254; }
    cp "$state/result.json" "$last"
    echo '{}'
    ;;
  's3api delete-object') : ;;
  'transcribe start-transcription-job') echo 'IN_PROGRESS' ;;
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
  'transcribe delete-transcription-job') : ;;
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
  out=$(env PATH="$fakebin:$PATH" ${wenv[@]+"${wenv[@]}"} bash "$wrapper" "$@" 2>&1)
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

finish() {
  echo "$pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
