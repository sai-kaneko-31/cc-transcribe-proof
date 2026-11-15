#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034
# (sandbox variables come from lib.sh)
#
# Tests for `transcribe.sh apply`: the corrector's edits are applied only when
# they are well formed and match the transcript exactly, speaker labels are
# never touched, and nothing is overwritten.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq > /dev/null 2>&1 || {
  echo 'SKIP test_apply.sh: jq is not installed, so the apply path is untested'
  exit 0
}

make_sandbox
trap cleanup_sandbox EXIT
wenv=()

transcript() { # writes the sample transcript to $sb/media/talk.transcript.txt
  rm -f "$sb"/media/talk.corrected.txt "$sb"/media/talk.corrections.json
  printf '%s\n' '[00:00 spk_0] 研修の件で確認します。' '[00:10 spk_1] 1,250点の請求書です。' '[00:20 spk_0] はいはい。' > "$sb/media/talk.transcript.txt"
}

edits() { printf '%s\n' "$1" > "$sb/edits.json"; }

corrected() { cat "$sb/media/talk.corrected.txt" 2> /dev/null; }

apply() { run_wrapper apply "$sb/media/talk.transcript.txt" "$sb/edits.json"; }

expect_corrected() { # label expected-text
  local got
  got=$(corrected)
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1" "got: $got"; fi
}

original='[00:00 spk_0] 研修の件で確認します。
[00:10 spk_1] 1,250点の請求書です。
[00:20 spk_0] はいはい。'

# ---- two valid edits ----
transcript
edits '{"edits":[
 {"line":1,"old":"研修の件","new":"検収の件","reason":"同音語","confidence":"high"},
 {"line":2,"old":"1,250点","new":"1,250件","reason":"数字の単位","confidence":"medium"}],
 "flags":[{"line":3,"text":"はいはい","reason":"繰り返しか相づちか分からない"}]}'
apply
expect_code 'valid edits exit 0' 0
expect_corrected 'edits are applied and the labels are untouched' '[00:00 spk_0] 検収の件で確認します。
[00:10 spk_1] 1,250件の請求書です。
[00:20 spk_0] はいはい。'
expect_out 'prints the corrected file path' "corrected_text=$sb/media/talk.corrected.txt"
expect_out 'prints the corrections file path' "corrections_json=$sb/media/talk.corrections.json"
expect_out 'prints the applied count' 'applied=2'
expect_out 'prints the rejected count' 'rejected=0'
expect_out 'prints the flagged count' 'flagged=1'
expect_out 'lists an applied edit' 'line 1: 研修の件 -> 検収の件'
expect_out 'lists a flagged item' 'line 3: はいはい'
[ "$(cat "$sb/media/talk.transcript.txt")" = "$original" ] && ok 'the original transcript is untouched' || bad 'the original transcript changed'
[ "$(jq '.applied | length' "$sb/media/talk.corrections.json")" = '2' ] && ok 'corrections.json holds the applied edits' || bad 'corrections.json applied count' "$(cat "$sb/media/talk.corrections.json")"
[ "$(jq '.flags | length' "$sb/media/talk.corrections.json")" = '1' ] && ok 'corrections.json holds the flags' || bad 'corrections.json flags count'
perm=$(ls -l "$sb/media/talk.corrected.txt" | cut -c1-10)
[ "$perm" = '-rw-------' ] && ok 'the corrected file is owner-only' || bad "corrected file permissions are $perm"
perm=$(ls -l "$sb/media/talk.corrections.json" | cut -c1-10)
[ "$perm" = '-rw-------' ] && ok 'the corrections file is owner-only' || bad "corrections file permissions are $perm"
expect_calls 'apply makes no aws call' 0 'ARGV'

# ---- two edits in one line are applied one after the other ----
transcript
edits '{"edits":[
 {"line":1,"old":"研修","new":"検収","reason":"同音語","confidence":"high"},
 {"line":1,"old":"確認します","new":"確認しました","reason":"時制","confidence":"medium"}],"flags":[]}'
apply
expect_corrected 'two edits in one line both apply' '[00:00 spk_0] 検収の件で確認しました。
[00:10 spk_1] 1,250点の請求書です。
[00:20 spk_0] はいはい。'

# ---- an edit that cannot be applied is rejected, the rest still applies ----
reject_case() { # label edit-json expected-reason-fragment
  transcript
  edits "{\"edits\":[$2,{\"line\":2,\"old\":\"1,250点\",\"new\":\"1,250件\",\"reason\":\"単位\",\"confidence\":\"high\"}],\"flags\":[]}"
  apply
  expect_code "$1: exit 0" 0
  expect_out "$1: counted as rejected" 'rejected=1'
  expect_out "$1: names the reason" "$3"
  expect_out "$1: the valid edit still applies" 'applied=1'
  if corrected | grep -q '1,250件'; then ok "$1: the valid edit is in the file"; else bad "$1: the valid edit is missing" "$(corrected)"; fi
}
reject_case 'old text not in the line' '{"line":1,"old":"存在しない","new":"x","reason":"r","confidence":"high"}' 'not found exactly once'
reject_case 'old text twice in the line' '{"line":3,"old":"はい","new":"x","reason":"r","confidence":"high"}' 'not found exactly once'
reject_case 'old text only in another line' '{"line":3,"old":"請求書","new":"x","reason":"r","confidence":"high"}' 'not found exactly once'
reject_case 'old text in the speaker label' '{"line":1,"old":"spk_0","new":"spk_1","reason":"r","confidence":"high"}' 'not found exactly once'
reject_case 'new text too long' '{"line":1,"old":"確認","new":"この文章は元の文に無い長い文を足しているので受け付けない。この文章は元の文に無い長い文を足しているので受け付けない。","reason":"r","confidence":"high"}' 'too long'
reject_case 'new text with a line break' '{"line":1,"old":"確認","new":"a\nb","reason":"r","confidence":"high"}' 'line break'
reject_case 'old equals new' '{"line":1,"old":"確認","new":"確認","reason":"r","confidence":"high"}' 'same'
reject_case 'empty old text' '{"line":1,"old":"","new":"x","reason":"r","confidence":"high"}' 'empty'
reject_case 'line number zero' '{"line":0,"old":"確認","new":"x","reason":"r","confidence":"high"}' 'line'
reject_case 'line number past the end' '{"line":9,"old":"確認","new":"x","reason":"r","confidence":"high"}' 'line'
reject_case 'line number as a string' '{"line":"1","old":"確認","new":"x","reason":"r","confidence":"high"}' 'line'
reject_case 'line number with a fraction' '{"line":1.5,"old":"確認","new":"x","reason":"r","confidence":"high"}' 'line'
reject_case 'unknown confidence' '{"line":1,"old":"確認","new":"x","reason":"r","confidence":"certain"}' 'confidence'
reject_case 'low confidence is not applied' '{"line":1,"old":"確認","new":"x","reason":"r","confidence":"low"}' 'confidence'
reject_case 'missing reason' '{"line":1,"old":"確認","new":"x","confidence":"high"}' 'reason'
reject_case 'an edit that is not an object' '"確認"' 'object'

# ---- a rejected edit leaves the line as it was ----
transcript
edits '{"edits":[{"line":1,"old":"存在しない","new":"x","reason":"r","confidence":"high"}],"flags":[]}'
apply
expect_corrected 'nothing changes when every edit is rejected' "$original"

# ---- no edits at all ----
transcript
edits '{"edits":[],"flags":[]}'
apply
expect_code 'an empty edit list exits 0' 0
expect_corrected 'an empty edit list copies the transcript' "$original"
expect_out 'an empty edit list reports applied=0' 'applied=0'

# ---- bad edit files exit 2 and write nothing ----
for body in 'not json' '[]' '{"edits":"x","flags":[]}' '{"flags":[]}' '{"edits":[]}' '{"edits":[],"flags":"x"}'; do
  transcript
  edits "$body"
  apply
  expect_code "edit file '$body' exits 2" 2
  [ -e "$sb/media/talk.corrected.txt" ] && bad "edit file '$body' wrote an output" || ok "edit file '$body' writes no output"
done

# ---- flags are checked too ----
transcript
edits '{"edits":[],"flags":[{"line":99,"text":"x","reason":"r"},{"line":1,"text":"確認","reason":"r"}]}'
apply
expect_code 'flags with a bad line still exit 0' 0
expect_out 'one flag is kept' 'flagged=1'
expect_out 'one flag is rejected' 'rejected=1'

# ---- files: never overwrite, no links, no missing files ----
transcript
edits '{"edits":[],"flags":[]}'
printf 'keep me\n' > "$sb/media/talk.corrected.txt"
apply
expect_code 'an existing corrected file exits 2' 2
[ "$(cat "$sb/media/talk.corrected.txt")" = 'keep me' ] && ok 'the existing corrected file is untouched' || bad 'the existing corrected file changed'
rm -f "$sb/media/talk.corrected.txt"
printf 'keep me too\n' > "$sb/media/talk.corrections.json"
apply
expect_code 'an existing corrections file exits 2' 2
[ -e "$sb/media/talk.corrected.txt" ] && bad 'a corrected file was written next to an existing corrections file' || ok 'nothing is written when the corrections file exists'
rm -f "$sb/media/talk.corrections.json"
ln -s "$sb/media/talk.transcript.txt" "$sb/media/link.txt"
run_wrapper apply "$sb/media/link.txt" "$sb/edits.json"
expect_code 'a symbolic link as the transcript exits 2' 2
run_wrapper apply "$sb/media/nothing.txt" "$sb/edits.json"
expect_code 'a missing transcript exits 2' 2
run_wrapper apply "$sb/media/talk.transcript.txt" "$sb/nothing.json"
expect_code 'a missing edit file exits 2' 2
run_wrapper apply "$sb/media/talk.transcript.txt"
expect_code 'a missing edit file argument exits 2' 2

# ---- output names ----
printf '%s\n' 'plain line one' > "$sb/media/notes.txt"
edits '{"edits":[{"line":1,"old":"one","new":"two","reason":"r","confidence":"high"}],"flags":[]}'
run_wrapper apply "$sb/media/notes.txt" "$sb/edits.json"
expect_code 'a plain text file works' 0
[ "$(cat "$sb/media/notes.corrected.txt" 2> /dev/null)" = 'plain line two' ] && ok 'notes.txt becomes notes.corrected.txt' || bad 'notes.txt output name' "$(ls "$sb/media")"
printf '%s\n' 'no extension' > "$sb/media/meeting"
edits '{"edits":[],"flags":[]}'
run_wrapper apply "$sb/media/meeting" "$sb/edits.json"
expect_code 'a file without an extension works' 0
[ -f "$sb/media/meeting.corrected.txt" ] && ok 'meeting becomes meeting.corrected.txt' || bad 'meeting output name' "$(ls "$sb/media")"

# ---- review findings: edits must not be able to rebuild a line or smuggle in text ----
apply_fresh() {
  rm -f "$sb"/media/talk.corrected.txt "$sb"/media/talk.corrections.json
  apply
}

raw_transcript() { # writes the given lines (printf format) as the transcript
  rm -f "$sb"/media/talk.corrected.txt "$sb"/media/talk.corrections.json
  printf "$1" > "$sb/media/talk.transcript.txt"
}

# chained edits may not grow a line without limit
raw_transcript '[00:00 spk_0] ア。イ。ウ。\n'
pad=$(printf 'あ%.0s' $(seq 1 19))
edits "{\"edits\":[
 {\"line\":1,\"old\":\"ア\",\"new\":\"ア$pad\",\"reason\":\"r\",\"confidence\":\"high\"},
 {\"line\":1,\"old\":\"イ\",\"new\":\"イ$pad\",\"reason\":\"r\",\"confidence\":\"high\"},
 {\"line\":1,\"old\":\"ウ\",\"new\":\"ウ$pad\",\"reason\":\"r\",\"confidence\":\"high\"}],\"flags\":[]}"
apply_fresh
expect_code 'chained edits exit 0' 0
expect_out 'a line may not keep growing' 'applied=1'
expect_out 'the growth limit is named' 'grow'
line_len=$(sed -n '1p' "$sb/media/talk.corrected.txt" | jq -R length)
[ "$line_len" -lt 80 ] && ok "the corrected line stays short ($line_len)" || bad "the corrected line has $line_len characters"

# control, format and line-separator characters in the new text are refused
bad_new_case() { # label new-text
  raw_transcript '[00:00 spk_0] 確認します。\n'
  jq -n --arg n "$2" '{edits:[{line:1,old:"確認",new:$n,reason:"r",confidence:"high"}],flags:[]}' > "$sb/edits.json"
  apply
  expect_out "$1 is rejected" 'rejected=1'
  expect_out "$1 gets the control-character reason" 'control or format character'
  [ "$(cat "$sb/media/talk.corrected.txt")" = '[00:00 spk_0] 確認します。' ] && ok "$1 leaves the line alone" || bad "$1 changed the line" "$(cat "$sb/media/talk.corrected.txt")"
}
bad_new_case 'a carriage return' $'x\r'
bad_new_case 'a tab' $'x\t'
bad_new_case 'U+2028 (line separator)' "$(printf 'x\342\200\250')"
bad_new_case 'U+2029 (paragraph separator)' "$(printf 'x\342\200\251')"
bad_new_case 'U+0085 (next line)' "$(printf 'x\302\205')"
bad_new_case 'U+202E (right-to-left override)' "$(printf 'x\342\200\256')"
bad_new_case 'U+200B (zero width space)' "$(printf 'x\342\200\213')"

# overlapping matches count: "はは" occurs twice in "ははは"
raw_transcript '[00:00 spk_0] ははは\n'
edits '{"edits":[{"line":1,"old":"はは","new":"あ","reason":"r","confidence":"high"}],"flags":[]}'
apply_fresh
expect_out 'an old text that overlaps itself is not unique' 'found 2 times'
expect_out 'it is rejected' 'rejected=1'

# a flag must quote text that is in its line
raw_transcript '[00:00 spk_0] 確認します。\n'
edits '{"edits":[],"flags":[{"line":1,"text":"ここに無い文字","reason":"r"},{"line":1,"text":"確認","reason":"r"}]}'
apply_fresh
expect_out 'a flag with text that is not in its line is rejected' 'rejected=1'
expect_out 'a flag with text that is in its line is kept' 'flagged=1'

# a flag may not carry control characters or be too long
long=$(printf 'あ%.0s' $(seq 1 201))
jq -n --arg t "$long" '{edits:[],flags:[{line:1,text:$t,reason:"r"}]}' > "$sb/edits.json"
apply_fresh
expect_out 'a flag text over 200 characters is rejected' 'rejected=1'
jq -n --arg r "$(printf 'x\342\200\256')" '{edits:[],flags:[{line:1,text:"確認",reason:$r}]}' > "$sb/edits.json"
apply_fresh
expect_out 'a flag reason with a control character is rejected' 'rejected=1'

# size limits: reason, old, number of edits and flags
raw_transcript '[00:00 spk_0] 確認します。\n'
jq -n --arg r "$long" '{edits:[{line:1,old:"確認",new:"検収",reason:$r,confidence:"high"}],flags:[]}' > "$sb/edits.json"
apply_fresh
expect_out 'a reason over 200 characters is rejected' 'reason is too long'
long_old=$(printf '確%.0s' $(seq 1 101))
raw_transcript "[00:00 spk_0] ${long_old}します。\\n"
jq -n --arg o "$long_old" '{edits:[{line:1,old:$o,new:"検",reason:"r",confidence:"high"}],flags:[]}' > "$sb/edits.json"
apply_fresh
expect_out 'an old text over 100 characters is rejected' 'old is too long'
raw_transcript '[00:00 spk_0] 確認します。\n'
jq -n '{edits:[range(0;201) | {line:1,old:"確認",new:"確認です",reason:"r",confidence:"high"}],flags:[]}' > "$sb/edits.json"
apply_fresh
expect_out 'more than 200 edits are refused' 'too many edits'
jq -n '{edits:[],flags:[range(0;51) | {line:1,text:"確認",reason:"r"}]}' > "$sb/edits.json"
apply_fresh
expect_out 'more than 50 flags are refused' 'too many flags'

# rejected edits are stored short, so the corrections file cannot be filled with arbitrary text
raw_transcript '[00:00 spk_0] 確認します。\n'
jq -n --arg o "$(printf '無%.0s' $(seq 1 5000))" '{edits:[{line:1,old:$o,new:"x",reason:"r",confidence:"high"}],flags:[]}' > "$sb/edits.json"
apply_fresh
stored=$(jq '.rejected[0].item | length' "$sb/media/talk.corrections.json" 2> /dev/null)
[ -n "$stored" ] && [ "$stored" -le 200 ] && ok "a rejected edit is stored in at most 200 characters ($stored)" || bad "stored rejected item length: $stored" "$(cat "$sb/media/talk.corrections.json")"
[ "$(printf '%s' "$out" | wc -c | tr -d ' ')" -lt 3000 ] && ok 'the printed output stays short' || bad 'the printed output is long'

# the user's ~/.jq must not change the rules
raw_transcript '[00:00 spk_0] 研修の件。\n'
mkdir -p "$sb/home"
printf 'def length: 0;\n' > "$sb/home/.jq"
edits '{"edits":[{"line":1,"old":"研修","new":"検収","reason":"r","confidence":"high"}],"flags":[]}'
wenv=("HOME=$sb/home")
apply_fresh
expect_out 'apply ignores ~/.jq' 'applied=1'
wenv=()

# a dangling link at an output name is not overwritten
raw_transcript '[00:00 spk_0] 確認します。\n'
edits '{"edits":[],"flags":[]}'
ln -s "$sb/nowhere" "$sb/media/talk.corrected.txt"
apply
expect_code 'a dangling link at the corrected name exits 2' 2
rm -f "$sb/media/talk.corrected.txt"
ln -s "$sb/nowhere" "$sb/media/talk.corrections.json"
apply
expect_code 'a dangling link at the corrections name exits 2' 2
rm -f "$sb/media/talk.corrections.json"

# git: the corrected files are checked too
rm -rf "$sb/repo"
mkdir -p "$sb/repo"
git -C "$sb/repo" init -q 2> /dev/null
printf '[00:00 spk_0] 確認します。\n' > "$sb/repo/talk.transcript.txt"
run_wrapper apply "$sb/repo/talk.transcript.txt" "$sb/edits.json"
expect_code 'apply inside a git work tree succeeds' 0
expect_out 'apply warns when git does not ignore the corrected files' 'WARNING'
rm -f "$sb"/repo/talk.corrected.txt "$sb"/repo/talk.corrections.json
printf '*.transcript.*\n*.corrected.txt\n*.corrections.json\n' > "$sb/repo/.gitignore"
run_wrapper apply "$sb/repo/talk.transcript.txt" "$sb/edits.json"
expect_no_out 'apply does not warn when git ignores them' 'WARNING'

# a sandbox that only lets the process write under TMPDIR (the plugin eval runs like this)
raw_transcript '[00:00 spk_0] 確認します。\n'
edits '{"edits":[],"flags":[]}'
rm -f "$state/mktemp.log"
mkdir -p "$sb/tmpdir"
wenv=("TMPDIR=$sb/tmpdir")
apply
expect_code 'apply works when only TMPDIR is writable' 0
expect_mktemp_under 'apply makes its temporary files under TMPDIR' "$sb/tmpdir" "$sb/media"
wenv=()

finish
