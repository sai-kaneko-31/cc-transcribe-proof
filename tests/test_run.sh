#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034
# (sandbox variables come from lib.sh)
#
# Tests for `transcribe.sh run`: the AWS call sequence, the scrubbed
# environment, cleanup on every exit path, and the output files. A fake `aws`
# stands in for the real one, so no AWS account is touched.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq > /dev/null 2>&1 || {
  echo 'SKIP test_run.sh: jq is not installed, so the run path is untested'
  exit 0
}

make_sandbox
trap cleanup_sandbox EXIT

printf '60\n' > "$state/duration"
f=$(media talk.wav)

# ---- happy path ----
base_env
fresh
run_wrapper run "$f"
expect_code 'run succeeds' 0
expect_file 'writes the transcript json next to the input' "$sb/media/talk.transcript.json"
expect_file 'writes the transcript text next to the input' "$sb/media/talk.transcript.txt"
expect_out 'prints the json path' "transcript_json=$sb/media/talk.transcript.json"
expect_out 'prints the text path' "transcript_text=$sb/media/talk.transcript.txt"
expect_no_out 'does not print transcript text' 'こんにちは'
if cmp -s "$sb/media/talk.transcript.json" "$state/result.json"; then ok 'json is the AWS result unchanged'; else bad 'json differs from the AWS result'; fi
expected_txt='[00:00 spk_0] こんにちは。
[00:04 spk_1] お願いします。
[01:05 spk_0] はい。'
if [ "$(cat "$sb/media/talk.transcript.txt")" = "$expected_txt" ]; then ok 'text has one line per speaker turn'; else bad 'text format differs' "$(cat "$sb/media/talk.transcript.txt")"; fi
perm=$(ls -l "$sb/media/talk.transcript.txt" | cut -c1-10)
[ "$perm" = '-rw-------' ] && ok 'text file is owner-only' || bad "text file permissions are $perm"
perm=$(ls -l "$sb/media/talk.transcript.json" | cut -c1-10)
[ "$perm" = '-rw-------' ] && ok 'json file is owner-only' || bad "json file permissions are $perm"

left=0
for p in "$state"/obj/*; do [ -e "$p" ] && left=$((left + 1)); done
[ "$left" -eq 0 ] && ok 'no object is left in the bucket (the access check file included)' || bad "$left objects left in the bucket"

# call sequence and arguments
expect_before 'checks the account before uploading' 'sts' 's3api] [put-object'
expect_before 'uploads before starting the job' 'put-object' 'start-transcription-job'
expect_before 'starts before fetching the result' 'start-transcription-job' 'get-object'
expect_before 'fetches the result before any cleanup' 'get-object' 'delete-transcription-job'
expect_before 'deletes the audio before the job' 'delete-object' 'delete-transcription-job'
job_line=$(line_of 'delete-transcription-job')
last_obj=$(last_line_of 'delete-object')
[ "$job_line" -gt 0 ] && [ "$job_line" -lt "$last_obj" ] && ok 'deletes the job before the result object' || bad "job delete at $job_line, last object delete at $last_obj"
expect_calls 'starts exactly one job' 1 'start-transcription-job'
expect_calls 'deletes the job once' 1 'delete-transcription-job'
expect_calls 'deletes the input, the access check file and the output object' 3 'delete-object'
expect_call_has 'start passes ja-JP' start-transcription-job '[--language-code] [ja-JP]'
expect_call_has 'start passes speaker labels with the default maximum' start-transcription-job '[--settings] [ShowSpeakerLabels=true,MaxSpeakerLabels=10]'
expect_call_has 'start writes into our bucket' start-transcription-job "[--output-bucket-name] [$bucket]"
expect_call_has 'start names an output key under the prefix' start-transcription-job '[--output-key] [transcribe-skill/'
s3_total=$(call_line s3api | wc -l | tr -d ' ')
s3_owned=$(call_line s3api | grep -c -F -e '[--expected-bucket-owner] [123456789012]')
[ "$s3_total" -gt 0 ] && [ "$s3_total" -eq "$s3_owned" ] && ok "all $s3_total s3api calls carry --expected-bucket-owner" || bad "s3api calls: $s3_total, with owner: $s3_owned" "$(cat "$state/calls.log")"
region_total=$(grep -c -F -e 'ARGV [--region] [ap-northeast-1]' "$state/calls.log")
all_total=$(wc -l < "$state/calls.log" | tr -d ' ')
[ "$region_total" -eq "$all_total" ] && ok 'every call passes --region first' || bad "calls with --region: $region_total of $all_total"
in_key=$(call_line put-object | sed -n 's/.*\[--key\] \[\([^]]*\)\].*/\1/p')
case "$in_key" in
  transcribe-skill/*/in/audio.wav) ok 'input key is under the prefix with a fixed name' ;;
  *) bad "input key is $in_key" ;;
esac
case "$in_key" in *talk*) bad 'input key contains the file name' ;; *) ok 'input key does not contain the file name' ;; esac
job=$(call_line start-transcription-job | sed -n 's/.*\[--transcription-job-name\] \[\([^]]*\)\].*/\1/p')
case "$job" in
  tsk-????????????????) ok 'job name is tsk- plus 16 characters' ;;
  *) bad "job name is $job" ;;
esac
case "$job" in *talk*) bad 'job name contains the file name' ;; *) ok 'job name does not contain the file name' ;; esac

# ---- a second run uses different random names ----
fresh
run_wrapper run "$f"
job2=$(call_line start-transcription-job | sed -n 's/.*\[--transcription-job-name\] \[\([^]]*\)\].*/\1/p')
[ "$job" != "$job2" ] && ok 'job names differ between runs' || bad 'job name repeated'

# ---- environment scrub ----
fresh
base_env
wenv+=("AWS_ACCESS_KEY_ID=BROADKEYBROADKEYBROAD" "AWS_SECRET_ACCESS_KEY=broadsecret" "AWS_PROFILE=admin"
  "AWS_SESSION_TOKEN=sessiontoken" "AWS_ENDPOINT_URL=http://evil.invalid" "AWS_ENDPOINT_URL_TRANSCRIBE=http://evil.invalid"
  "AWS_ENDPOINT_URL_S3=http://evil.invalid" "AWS_CONFIG_FILE=/nonexistent/config" "AWS_SHARED_CREDENTIALS_FILE=/nonexistent/credentials"
  "AWS_DEFAULT_REGION=us-east-1" "AWS_REGION=us-east-1" "PYTHONPATH=/evil" "LD_LIBRARY_PATH=/evil" "BASH_ENV=/evil"
  "SOME_OTHER_SECRET=leak" "HTTPS_PROXY=http://proxy.invalid:8080")
run_wrapper run "$f"
expect_code 'run succeeds with a hostile environment' 0
envs=$(ls "$state"/env-*.txt 2> /dev/null | wc -l | tr -d ' ')
[ "$envs" -gt 0 ] && ok "captured the environment of $envs aws calls" || bad 'no aws environment captured'
all_env=$(cat "$state"/env-*.txt)
n_calls=$(wc -l < "$state/calls.log" | tr -d ' ')
n_key=$(printf '%s\n' "$all_env" | grep -c -x -F -e "AWS_ACCESS_KEY_ID=$key_id")
[ "$n_key" -eq "$envs" ] && ok 'every call uses the plugin access key' || bad "plugin key in $n_key of $envs calls"
n_sec=$(printf '%s\n' "$all_env" | grep -c -x -F -e "AWS_SECRET_ACCESS_KEY=$secret")
[ "$n_sec" -eq "$envs" ] && ok 'every call uses the plugin secret key' || bad "plugin secret in $n_sec of $envs calls"
for var in AWS_PROFILE AWS_SESSION_TOKEN AWS_ENDPOINT_URL AWS_ENDPOINT_URL_TRANSCRIBE AWS_ENDPOINT_URL_S3 AWS_REGION PYTHONPATH LD_LIBRARY_PATH BASH_ENV SOME_OTHER_SECRET TRANSCRIBE_AWS_ACCESS_KEY_ID TRANSCRIBE_AWS_SECRET_ACCESS_KEY; do
  if printf '%s\n' "$all_env" | grep -q "^$var="; then bad "$var reaches aws"; else ok "$var does not reach aws"; fi
done
n_cfg=$(printf '%s\n' "$all_env" | grep -c -x -F -e 'AWS_CONFIG_FILE=/dev/null')
[ "$n_cfg" -eq "$envs" ] && ok 'the AWS config file is /dev/null' || bad "AWS_CONFIG_FILE=/dev/null in $n_cfg of $envs calls"
n_cred=$(printf '%s\n' "$all_env" | grep -c -x -F -e 'AWS_SHARED_CREDENTIALS_FILE=/dev/null')
[ "$n_cred" -eq "$envs" ] && ok 'the shared credentials file is /dev/null' || bad "AWS_SHARED_CREDENTIALS_FILE=/dev/null in $n_cred of $envs calls"
n_reg=$(printf '%s\n' "$all_env" | grep -c -x -F -e 'AWS_DEFAULT_REGION=ap-northeast-1')
[ "$n_reg" -eq "$envs" ] && ok 'the default region is the plugin region' || bad "AWS_DEFAULT_REGION in $n_reg of $envs calls"
n_ep=$(printf '%s\n' "$all_env" | grep -c -x -F -e 'AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true')
[ "$n_ep" -eq "$envs" ] && ok 'configured endpoint URLs are ignored' || bad "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS in $n_ep of $envs calls"
n_proxy=$(printf '%s\n' "$all_env" | grep -c -x -F -e 'HTTPS_PROXY=http://proxy.invalid:8080')
[ "$n_proxy" -eq "$envs" ] && ok 'a proxy setting is kept' || bad "HTTPS_PROXY in $n_proxy of $envs calls"
: "$n_calls"

# ---- required settings: missing or malformed -> exit 2 before any AWS call ----
for var in TRANSCRIBE_AWS_ACCESS_KEY_ID TRANSCRIBE_AWS_SECRET_ACCESS_KEY TRANSCRIBE_AWS_REGION TRANSCRIBE_S3_BUCKET; do
  fresh
  base_env
  kept=()
  for item in "${wenv[@]}"; do case "$item" in "$var="*) ;; *) kept+=("$item") ;; esac; done
  wenv=("${kept[@]}")
  run_wrapper run "$f"
  expect_code "missing $var exits 2" 2
  expect_out "names $var when it is missing" "$var"
  expect_calls "missing $var makes no aws call" 0 'ARGV'
done
for bad_value in 'TRANSCRIBE_AWS_ACCESS_KEY_ID=short' "TRANSCRIBE_AWS_SECRET_ACCESS_KEY=$secret""x" 'TRANSCRIBE_AWS_REGION=Tokyo' 'TRANSCRIBE_AWS_REGION=ap-northeast-1;rm' 'TRANSCRIBE_S3_BUCKET=Bad_Bucket' 'TRANSCRIBE_S3_BUCKET=a..b' 'TRANSCRIBE_S3_BUCKET=s3://name'; do
  fresh
  base_env
  wenv+=("$bad_value")
  run_wrapper run "$f"
  expect_code "malformed ${bad_value%%=*} ($bad_value) exits 2" 2
  expect_calls "malformed ${bad_value%%=*} makes no aws call" 0 'ARGV'
done

# ---- --max-speakers ----
base_env
fresh
run_wrapper run "$f" --max-speakers 4
expect_code '--max-speakers 4 succeeds' 0
expect_call_has '--max-speakers 4 reaches the job settings' start-transcription-job 'MaxSpeakerLabels=4]'
for bad_n in 1 31 abc '' '4;x'; do
  fresh
  run_wrapper run "$f" --max-speakers "$bad_n"
  expect_code "--max-speakers '$bad_n' exits 2" 2
  expect_calls "--max-speakers '$bad_n' makes no aws call" 0 'ARGV'
done
fresh
run_wrapper run "$f" --unknown-option
expect_code 'unknown option exits 2' 2

# ---- existing outputs are never overwritten ----
fresh
printf 'keep me\n' > "$sb/media/talk.transcript.txt"
run_wrapper run "$f"
expect_code 'existing text output exits 2' 2
expect_calls 'existing output makes no aws call' 0 'ARGV'
[ "$(cat "$sb/media/talk.transcript.txt")" = 'keep me' ] && ok 'existing output is untouched' || bad 'existing output was changed'
rm -f "$sb/media/talk.transcript.txt"
fresh
printf 'keep me too\n' > "$sb/media/talk.transcript.json"
run_wrapper run "$f"
expect_code 'existing json output exits 2' 2
expect_calls 'existing json output makes no aws call' 0 'ARGV'
[ "$(cat "$sb/media/talk.transcript.json")" = 'keep me too' ] && ok 'existing json output is untouched' || bad 'existing json output was changed'
rm -f "$sb/media/talk.transcript.json"

# ---- failures: exit 1, no outputs, cleanup of what exists, no retry ----
fresh
: > "$state/fail-put-object"
run_wrapper run "$f"
expect_code 'upload failure exits 1' 1
expect_calls 'upload failure never starts a job' 0 'start-transcription-job'
expect_calls 'upload failure deletes no job' 0 'delete-transcription-job'
expect_calls 'upload failure still removes the possible objects' 3 'delete-object'
expect_calls 'upload is not retried' 1 'put-object'
expect_no_file 'upload failure writes no json' "$sb/media/talk.transcript.json"

fresh
: > "$state/fail-start-transcription-job"
run_wrapper run "$f"
expect_code 'start failure exits 1' 1
expect_calls 'start is not retried' 1 'start-transcription-job'
expect_calls 'start failure removes the objects' 3 'delete-object'
expect_no_file 'start failure writes no json' "$sb/media/talk.transcript.json"

fresh
printf 'IN_PROGRESS\nFAILED\n' > "$state/status-seq"
printf 'The data in your input media file isn'"'"'t valid.\n' > "$state/failure-reason"
run_wrapper run "$f"
expect_code 'a FAILED job exits 1' 1
expect_out 'shows the failure reason' 'input media file'
expect_calls 'a FAILED job is deleted' 1 'delete-transcription-job'
expect_calls 'a FAILED job removes the objects' 3 'delete-object'
expect_calls 'a FAILED job is not restarted' 1 'start-transcription-job'
expect_no_file 'a FAILED job writes no json' "$sb/media/talk.transcript.json"

fresh
: > "$state/fail-get-transcription-job"
run_wrapper run "$f"
expect_code 'a status check failure exits 1' 1
expect_calls 'a status check failure still deletes the job' 1 'delete-transcription-job'
expect_calls 'a status check failure removes the objects' 3 'delete-object'

fresh
: > "$state/fail-get-object"
run_wrapper run "$f"
expect_code 'a result download failure exits 1' 1
expect_calls 'a download failure still deletes the job' 1 'delete-transcription-job'
expect_calls 'a download failure removes the objects' 3 'delete-object'
expect_no_file 'a download failure writes no json' "$sb/media/talk.transcript.json"
expect_no_file 'a download failure writes no text' "$sb/media/talk.transcript.txt"

fresh
printf 'not json at all\n' > "$state/result.json"
run_wrapper run "$f"
expect_code 'an unreadable result exits 1' 1
expect_calls 'an unreadable result still deletes the job' 1 'delete-transcription-job'
expect_no_file 'an unreadable result writes no json' "$sb/media/talk.transcript.json"
stray=0
for p in "$sb"/media/.transcribe.*; do [ -e "$p" ] && stray=$((stray + 1)); done
[ "$stray" -eq 0 ] && ok 'no temp files are left behind' || bad "$stray temp files left in the output directory"

# ---- cleanup that fails: outputs are written, exit 3, leftovers are named ----
fresh
: > "$state/fail-delete-object"
run_wrapper run "$f"
expect_code 'a cleanup failure exits 3' 3
expect_file 'the outputs are still written after a cleanup failure' "$sb/media/talk.transcript.txt"
expect_out 'names the leftover object' 'transcribe-skill/'

# ---- a job that never finishes: bounded wait, then cleanup ----
fresh
printf 'IN_PROGRESS\n' > "$state/status-seq"
run_wrapper run "$f"
expect_code 'a job that never finishes exits 1' 1
expect_out 'says the wait ran out' 'did not finish'
expect_calls 'a timed-out job is deleted' 1 'delete-transcription-job'

# ---- a signal during the wait still cleans up ----
fresh
printf 'IN_PROGRESS\n' > "$state/status-seq"
(exec env PATH="$fakebin:$PATH" "${wenv[@]}" "$BASH" "$wrapper" run "$f" > "$sb/signal.out" 2>&1) &
pid=$!
for _ in $(seq 1 400); do
  [ "$(cat "$state/get-count" 2> /dev/null || echo 0)" -ge 3 ] && break
  sleep 0.05
done
kill -TERM "$pid" 2> /dev/null
wait "$pid"
code=$?
[ "$code" -ne 0 ] && ok "SIGTERM ends the run with a failure code ($code)" || bad 'SIGTERM exit code was 0'
expect_calls 'SIGTERM still deletes the job' 1 'delete-transcription-job'
expect_calls 'SIGTERM still removes the objects' 3 'delete-object'

# ---- git work tree warning ----
fresh
mkdir -p "$sb/repo"
cp "$f" "$sb/repo/talk.wav"
git -C "$sb/repo" init -q 2> /dev/null
run_wrapper run "$sb/repo/talk.wav"
expect_code 'a run inside a git work tree succeeds' 0
expect_out 'warns when the output is not ignored by git' 'git'
rm -f "$sb"/repo/*.transcript.*
fresh
printf '*.transcript.*\n*.corrected.txt\n*.corrections.json\n' > "$sb/repo/.gitignore"
run_wrapper run "$sb/repo/talk.wav"
expect_code 'a run inside an ignoring git work tree succeeds' 0
expect_no_out 'does not warn when git ignores the output' 'WARNING'
fresh
run_wrapper run "$f"
expect_no_out 'does not warn outside a git work tree' 'WARNING'

# ---- review findings: cleanup under signals ----
# wait_for_hang: waits until the fake aws says it is blocked.
wait_for_hang() {
  local _
  for _ in $(seq 1 400); do
    [ -e "$state/hanging" ] && return 0
    sleep 0.05
  done
  return 1
}

# A signal that arrives while the job is being started: the job may exist on AWS, so it is deleted.
fresh
: > "$state/hang-start"
(exec env PATH="$fakebin:$PATH" "${wenv[@]}" "$BASH" "$wrapper" run "$f" > "$sb/signal.out" 2>&1) &
pid=$!
wait_for_hang || bad 'the fake start never blocked'
kill -TERM "$pid" 2> /dev/null
: > "$state/release"
wait "$pid"
code=$?
[ "$code" -ne 0 ] && ok "SIGTERM during start ends the run with a failure code ($code)" || bad 'SIGTERM during start exited 0'
expect_calls 'SIGTERM during start still deletes the job' 1 'delete-transcription-job'
expect_calls 'SIGTERM during start still removes the objects' 3 'delete-object'

# A second signal during cleanup must not interrupt the cleanup.
fresh
: > "$state/hang-delete"
(exec env PATH="$fakebin:$PATH" "${wenv[@]}" "$BASH" "$wrapper" run "$f" > "$sb/signal.out" 2>&1) &
pid=$!
wait_for_hang || bad 'the fake job delete never blocked'
kill -TERM "$pid" 2> /dev/null
sleep 0.1
kill -TERM "$pid" 2> /dev/null
sleep 0.1
: > "$state/release"
wait "$pid"
code=$?
expect_calls 'two signals during cleanup still remove both objects' 3 'delete-object'
expect_calls 'two signals during cleanup still finish the job delete' 1 'delete-transcription-job'
first_obj=$(line_of 'delete-object')
job_del=$(line_of 'delete-transcription-job')
[ "$first_obj" -gt 0 ] && [ "$first_obj" -lt "$job_del" ] && ok 'the audio is deleted before the job' || bad "delete-object at $first_obj, delete-transcription-job at $job_del"

# A job that was not finished when cleanup ran may still write its output: say so.
fresh
printf 'IN_PROGRESS\n' > "$state/status-seq"
run_wrapper run "$f"
expect_code 'an unfinished job exits 1' 1
expect_out 'an unfinished job names the output that may appear later' 'later'

# ---- review findings: buckets with versioning keep deleted objects ----
fresh
: > "$state/versioned"
run_wrapper run "$f"
expect_code 'a versioned bucket exits 3 because deleted objects remain as old versions' 3
expect_file 'a versioned bucket still gets the outputs' "$sb/media/talk.transcript.txt"
expect_out 'a versioned bucket names the objects that remain' 'transcribe-skill/'
expect_out 'a versioned bucket explains the cause' 'version'

# ---- review findings: the user's HOME must not reach the AWS CLI or jq ----
fresh
mkdir -p "$sb/home/.aws/cli"
printf '[toplevel]\nsts = !echo hijacked\n' > "$sb/home/.aws/cli/alias"
printf 'def length: 0;\n' > "$sb/home/.jq"
wenv+=("HOME=$sb/home")
run_wrapper run "$f"
expect_code 'a hostile HOME does not break the run' 0
expected_txt='[00:00 spk_0] こんにちは。
[00:04 spk_1] お願いします。
[01:05 spk_0] はい。'
[ "$(cat "$sb/media/talk.transcript.txt")" = "$expected_txt" ] && ok 'jq ignores ~/.jq' || bad 'jq read ~/.jq' "$(cat "$sb/media/talk.transcript.txt" 2> /dev/null)"
envs=$(ls "$state"/env-*.txt | wc -l | tr -d ' ')
real_home=$(grep -c -x -F -e "HOME=$sb/home" "$state"/env-*.txt | awk -F: '{s += $2} END {print s + 0}')
[ "$real_home" -eq 0 ] && ok "no aws call sees the user's HOME ($envs calls)" || bad "$real_home aws calls saw HOME=$sb/home"
base_env

# ---- review findings: output names that are dangling links, and git coverage of every output ----
fresh
ln -s "$sb/nowhere" "$sb/media/talk.transcript.json"
run_wrapper run "$f"
expect_code 'a dangling link at an output name exits 2' 2
expect_calls 'a dangling link makes no aws call' 0 'ARGV'
rm -f "$sb/media/talk.transcript.json"

fresh
rm -rf "$sb/repo"
mkdir -p "$sb/repo"
cp "$f" "$sb/repo/talk.wav"
git -C "$sb/repo" init -q 2> /dev/null
printf '*.transcript.*\n' > "$sb/repo/.gitignore"
run_wrapper run "$sb/repo/talk.wav"
expect_code 'a run with only the transcript names ignored succeeds' 0
expect_out 'warns when the corrected outputs are not ignored' 'WARNING'

finish
