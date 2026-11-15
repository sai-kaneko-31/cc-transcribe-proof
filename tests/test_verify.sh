#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034
# (sandbox variables come from lib.sh)
#
# Tests for `transcribe.sh verify`: each check reports ok or NG, secrets and the
# account ID are never printed, and every probe object and job is removed.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_sandbox
trap cleanup_sandbox EXIT

# verify_status: a probe job that ends FAILED, as a text file posing as audio does.
ready() {
  base_env
  fresh
  printf 'IN_PROGRESS\nFAILED\n' > "$state/status-seq"
}

leftover_objects() {
  local n=0 p
  for p in "$state"/obj/*; do [ -e "$p" ] && n=$((n + 1)); done
  echo "$n"
}

# ---- everything fine ----
ready
run_wrapper verify
expect_code 'verify passes with a correctly limited key' 0
for c in env identity broad-key bucket-rw bucket-outside-prefix bucket-list transcribe-start transcribe-get transcribe-delete; do
  expect_out "check $c is reported ok" "check $c: ok"
done
expect_out 'ends with result=ok' 'result=ok'
expect_out 'shows the user name of the key' 'fake-transcribe-user'
expect_no_out 'never prints the access key ID' "$key_id"
expect_no_out 'never prints the secret key' "$secret"
expect_no_out 'never prints the account ID' '123456789012'
expect_calls 'starts one probe job' 1 'start-transcription-job'
expect_calls 'deletes the probe job' 1 'delete-transcription-job'
expect_call_has 'the probe job writes into our bucket' start-transcription-job "[--output-bucket-name] [$bucket]"
expect_call_has 'the probe job uses a .wav media file' start-transcription-job '/audio.wav]'
s3_total=$(call_line s3api | wc -l | tr -d ' ')
s3_owned=$(call_line s3api | grep -c -F -e '[--expected-bucket-owner] [123456789012]')
[ "$s3_total" -gt 0 ] && [ "$s3_total" -eq "$s3_owned" ] && ok "all $s3_total s3api calls carry --expected-bucket-owner" || bad "s3api calls: $s3_total, with owner: $s3_owned" "$(cat "$state/calls.log")"
[ "$(leftover_objects)" -eq 0 ] && ok 'no probe object is left in the bucket' || bad "$(leftover_objects) probe objects left"
expect_call_has 'tries to read iam:ListUsers' iam '[list-users]'
expect_call_has 'tries to list the bucket' s3api '[list-objects-v2]'
outside_keys=$(call_line put-object | sed -n 's/.*\[--key\] \[\([^]]*\)\].*/\1/p' | grep -v '^transcribe-skill/' | wc -l | tr -d ' ')
[ "$outside_keys" -eq 1 ] && ok 'tries one write outside the prefix' || bad "$outside_keys writes outside the prefix"

# ---- a broad key is reported ----
ready
: > "$state/broad-key"
run_wrapper verify
expect_code 'a key that can list IAM users fails verify' 1
expect_out 'reports the broad key' 'check broad-key: NG'
expect_out 'ends with result=ng' 'result=ng'
expect_out 'the other checks still run' 'check bucket-rw: ok'

# ---- root user keys are reported ----
ready
: > "$state/root-arn"
run_wrapper verify
expect_code 'root user keys fail verify' 1
expect_out 'reports root user keys' 'check identity: NG'
expect_out 'says why root keys are refused' 'root user'

# ---- a writable bucket outside the prefix is reported, and cleaned up ----
ready
: > "$state/allow-outside-put"
run_wrapper verify
expect_code 'a key that can write outside the prefix fails verify' 1
expect_out 'reports the outside write' 'check bucket-outside-prefix: NG'
[ "$(leftover_objects)" -eq 0 ] && ok 'the stray outside object is removed' || bad "$(leftover_objects) objects left after an outside write"

# ---- a key that can list the bucket is reported ----
ready
: > "$state/allow-list"
run_wrapper verify
expect_code 'a key that can list the bucket fails verify' 1
expect_out 'reports the listing' 'check bucket-list: NG'

# ---- missing or malformed settings stop before any AWS call ----
for var in TRANSCRIBE_AWS_ACCESS_KEY_ID TRANSCRIBE_AWS_SECRET_ACCESS_KEY TRANSCRIBE_AWS_REGION TRANSCRIBE_S3_BUCKET; do
  ready
  kept=()
  for item in "${wenv[@]}"; do case "$item" in "$var="*) ;; *) kept+=("$item") ;; esac; done
  wenv=("${kept[@]}")
  run_wrapper verify
  expect_code "missing $var exits 2" 2
  expect_out "reports the env check as NG when $var is missing" 'check env: NG'
  expect_out "names $var" "$var"
  expect_calls "missing $var makes no aws call" 0 'ARGV'
done
ready
wenv+=("TRANSCRIBE_AWS_ACCESS_KEY_ID=short")
run_wrapper verify
expect_code 'a short access key ID exits 2' 2
expect_no_out 'a short access key ID is not echoed back' '=short'
expect_calls 'a short access key ID makes no aws call' 0 'ARGV'

# ---- the key does not work at all ----
ready
: > "$state/fail-get-caller-identity"
run_wrapper verify
expect_code 'an unusable key exits 1' 1
expect_out 'reports the identity check as NG' 'check identity: NG'
expect_calls 'an unusable key stops before writing to the bucket' 0 'put-object'

# ---- a download that differs from the upload ----
ready
: > "$state/corrupt-get"
run_wrapper verify
expect_code 'a download that differs from the upload fails verify' 1
expect_out 'reports the read-write check as NG' 'check bucket-rw: NG'

# ---- reading the probe job is denied ----
ready
: > "$state/fail-get-transcription-job"
run_wrapper verify
expect_code 'a denied status read fails verify' 1
expect_out 'reports the get check as NG' 'check transcribe-get: NG'
expect_calls 'a denied status read still deletes the probe job' 1 'delete-transcription-job'

# ---- a bucket with versioning keeps deleted objects as old versions ----
ready
: > "$state/versioned"
run_wrapper verify
expect_code 'a versioned bucket fails verify' 1
expect_out 'reports the versioned bucket in the read-write check' 'check bucket-rw: NG the bucket has versioning on'

# ---- the bucket upload fails ----
ready
: > "$state/fail-put-object"
run_wrapper verify
expect_code 'a failing upload exits 1' 1
expect_out 'reports the bucket read-write check as NG' 'check bucket-rw: NG'
expect_out 'does not claim the Transcribe checks passed' 'check transcribe-start: NG'
expect_calls 'a failing upload starts no job' 0 'start-transcription-job'

# ---- Transcribe start is denied ----
ready
: > "$state/fail-start-transcription-job"
run_wrapper verify
expect_code 'a denied start exits 1' 1
expect_out 'reports the start check as NG' 'check transcribe-start: NG'
expect_no_out 'a denied start does not report a leftover job' 'WARNING'
[ "$(leftover_objects)" -eq 0 ] && ok 'a denied start still removes the probe objects' || bad "$(leftover_objects) objects left after a denied start"

# ---- Transcribe delete is denied: the job name is shown so it can be removed by hand ----
ready
: > "$state/fail-delete-transcription-job"
run_wrapper verify
expect_code 'a denied delete exits 1' 1
expect_out 'reports the delete check as NG' 'check transcribe-delete: NG'
expect_out 'names the leftover job' 'tsk-'

# ---- a probe job that keeps running: the wait is bounded ----
ready
printf 'IN_PROGRESS\n' > "$state/status-seq"
run_wrapper verify
expect_out 'a still-running probe job still passes the get check' 'check transcribe-get: ok'
expect_calls 'a still-running probe job is deleted' 1 'delete-transcription-job'

# ---- the caller's environment does not reach aws ----
ready
wenv+=("AWS_ACCESS_KEY_ID=BROADKEYBROADKEYBROAD" "AWS_PROFILE=admin" "AWS_ENDPOINT_URL=http://evil.invalid")
run_wrapper verify
expect_code 'verify passes with a hostile environment' 0
all_env=$(cat "$state"/env-*.txt)
envs=$(ls "$state"/env-*.txt | wc -l | tr -d ' ')
n_key=$(printf '%s\n' "$all_env" | grep -c -x -F -e "AWS_ACCESS_KEY_ID=$key_id")
[ "$n_key" -eq "$envs" ] && ok 'every verify call uses the plugin access key' || bad "plugin key in $n_key of $envs calls"
if printf '%s\n' "$all_env" | grep -q -e '^AWS_PROFILE=' -e '^AWS_ENDPOINT_URL='; then bad 'a profile or endpoint override reaches aws'; else ok 'no profile or endpoint override reaches aws'; fi

# ---- the user's HOME does not reach the AWS CLI ----
ready
mkdir -p "$sb/home"
wenv+=("HOME=$sb/home")
run_wrapper verify
expect_code 'verify passes with another HOME' 0
home_hits=$(grep -c -x -F -e "HOME=$sb/home" "$state"/env-*.txt | awk -F: '{s += $2} END {print s + 0}')
[ "$home_hits" -eq 0 ] && ok "no aws call sees the user's HOME" || bad "$home_hits aws calls saw the user's HOME"

# ---- a sandbox that only lets the process write under TMPDIR (the plugin eval runs like this) ----
ready
rm -f "$state/mktemp.log"
mkdir -p "$sb/tmpdir"
wenv+=("TMPDIR=$sb/tmpdir")
run_wrapper verify
expect_code 'verify works when only TMPDIR is writable' 0
expect_mktemp_under 'verify makes its temporary files under TMPDIR' "$sb/tmpdir"

finish
