#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034
# (sandbox variables come from lib.sh)
#
# Tests for `transcribe.sh estimate`: input checks, duration and cost, and that
# no AWS call is made.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_sandbox
trap cleanup_sandbox EXIT
wenv=()

# valid input: 60 minutes of audio
printf '3600\n' > "$state/duration"
f=$(media talk.wav)
run_wrapper estimate "$f"
expect_code 'valid wav exits 0' 0
expect_out 'prints the duration in seconds' 'duration_seconds=3600'
expect_out 'prints the estimated cost for 60 minutes' 'estimated_cost_usd=0.360'
expect_out 'prints the unit price used' 'unit_price_usd_per_minute=0.006'
expect_out 'prints the price basis as an estimate' 'price_basis='
expect_out 'prints the duration limit' 'limit_duration_minutes=120'
expect_calls 'estimate makes no aws call' 0 'ARGV'

# every allowed extension, in either case
for name in a.mp3 a.mp4 a.m4a a.wav a.flac a.ogg a.webm a.amr B.MP3 C.Wav; do
  f=$(media "$name")
  run_wrapper estimate "$f"
  expect_code "extension of $name is accepted" 0
done

# rejected extensions
for name in a.txt a.exe a.sh a.mp3.txt noext; do
  f=$(media "$name")
  run_wrapper estimate "$f"
  expect_code "extension of $name is rejected" 2
done

# duration limit: 120 minutes passes, one second more fails
printf '7200\n' > "$state/duration"
f=$(media edge.wav)
run_wrapper estimate "$f"
expect_code '120 minutes is accepted' 0
printf '7201\n' > "$state/duration"
run_wrapper estimate "$f"
expect_code '120 minutes and 1 second is rejected' 2
expect_out 'says the duration limit' '120'

# non-positive and non-numeric durations
printf '0\n' > "$state/duration"
run_wrapper estimate "$f"
expect_code 'zero duration is rejected' 2
printf '60\n' > "$state/duration"
: > "$state/ffprobe-garbage"
run_wrapper estimate "$f"
expect_code 'non-numeric duration is rejected' 2
rm -f "$state/ffprobe-garbage"
: > "$state/ffprobe-fail"
run_wrapper estimate "$f"
expect_code 'ffprobe failure is rejected' 2
rm -f "$state/ffprobe-fail"

# ffprobe missing from PATH (skipped when the system PATH already has one)
if PATH=/usr/bin:/bin command -v ffprobe > /dev/null 2>&1; then
  echo 'SKIP missing ffprobe: a system ffprobe is on /usr/bin or /bin'
else
  out=$(env PATH="$sb/nobin:/usr/bin:/bin" bash "$wrapper" estimate "$f" 2>&1)
  code=$?
  expect_code 'missing ffprobe exits 2' 2
  expect_out 'names ffprobe when it is missing' 'ffprobe'
fi

# path problems
run_wrapper estimate "$sb/media/missing.wav"
expect_code 'missing file is rejected' 2
run_wrapper estimate "$sb/media"
expect_code 'directory is rejected' 2
run_wrapper estimate
expect_code 'no path is rejected' 2
ln -s "$f" "$sb/media/link.wav"
run_wrapper estimate "$sb/media/link.wav"
expect_code 'symlink is rejected' 2
expect_out 'says why a symlink is rejected' 'symbolic link'
nl_path="$sb/media/new
line.wav"
printf 'x\n' > "$nl_path"
run_wrapper estimate "$nl_path"
expect_code 'path with a newline is rejected' 2

# size limit (a sparse file, so the test does not write 2 GB)
dd if=/dev/null of="$sb/media/big.wav" bs=1 count=0 seek=2100000000 2> /dev/null
run_wrapper estimate "$sb/media/big.wav"
expect_code 'file over the size limit is rejected' 2
expect_out 'says the size limit' 'size'

# empty file
: > "$sb/media/empty.wav"
run_wrapper estimate "$sb/media/empty.wav"
expect_code 'empty file is rejected' 2

# output paths and the git work tree flag
f=$(media talk.wav)
run_wrapper estimate "$f"
expect_out 'prints the json output path' "output_json=$sb/media/talk.transcript.json"
expect_out 'prints the text output path' "output_text=$sb/media/talk.transcript.txt"
expect_out 'outside git, the git flag is no' 'output_in_unignored_git_worktree=no'
mkdir -p "$sb/repo"
cp "$f" "$sb/repo/talk.wav"
git -C "$sb/repo" init -q 2> /dev/null
run_wrapper estimate "$sb/repo/talk.wav"
expect_out 'inside git and not ignored, the git flag is yes' 'output_in_unignored_git_worktree=yes'
printf '*.transcript.*\n*.corrected.txt\n*.corrections.json\n' > "$sb/repo/.gitignore"
run_wrapper estimate "$sb/repo/talk.wav"
expect_out 'inside git and ignored, the git flag is no' 'output_in_unignored_git_worktree=no'

# a file name with backslashes must not add lines to the output (awk -v would expand them)
name='x\nestimated_cost_usd=0.000\ny.wav'
f=$(media "$name")
run_wrapper estimate "$f"
expect_code 'a file name with backslash sequences is accepted' 0
n_cost=$(printf '%s\n' "$out" | grep -c '^estimated_cost_usd=')
[ "$n_cost" -eq 1 ] && ok 'the name cannot add an estimated_cost_usd line' || bad "estimated_cost_usd appears on $n_cost lines" "$out"
n_git=$(printf '%s\n' "$out" | grep -c '^output_in_unignored_git_worktree=')
[ "$n_git" -eq 1 ] && ok 'the name cannot add a git flag line' || bad "git flag appears on $n_git lines" "$out"

# control characters in a path are refused
f="$sb/media/tab"$'\t'"name.wav"
printf 'x\n' > "$f"
run_wrapper estimate "$f"
expect_code 'a path with a tab is rejected' 2

# git: only some of the outputs ignored still counts as unignored
printf '*.transcript.*\n' > "$sb/repo/.gitignore"
run_wrapper estimate "$sb/repo/talk.wav"
expect_out 'the corrected outputs count too' 'output_in_unignored_git_worktree=yes'
expect_out 'the corrected text path is printed' "output_corrected_text=$sb/repo/talk.corrected.txt"
expect_out 'the corrections path is printed' "output_corrections_json=$sb/repo/talk.corrections.json"

# git: a repository's core.fsmonitor command must not run
mkdir -p "$sb/fsrepo"
git -C "$sb/fsrepo" init -q 2> /dev/null
printf '#!/bin/sh\ntouch "%s"\n' "$sb/fsmonitor-ran" > "$sb/fsm.sh"
chmod +x "$sb/fsm.sh"
git -C "$sb/fsrepo" config core.fsmonitor "$sb/fsm.sh"
cp "$(media talk2.wav)" "$sb/fsrepo/talk.wav"
git -C "$sb/fsrepo" check-ignore -q -- "$sb/fsrepo/talk.transcript.json"
if [ -e "$sb/fsmonitor-ran" ]; then
  rm -f "$sb/fsmonitor-ran"
  run_wrapper estimate "$sb/fsrepo/talk.wav"
  expect_code 'a run inside a repository with core.fsmonitor succeeds' 0
  [ -e "$sb/fsmonitor-ran" ] && bad 'estimate ran the core.fsmonitor command of the repository' || ok 'estimate does not run core.fsmonitor'
else
  echo 'SKIP fsmonitor: this git does not run core.fsmonitor for check-ignore, so the protection is untested'
fi

# unknown subcommand and no subcommand
run_wrapper frobnicate
expect_code 'unknown subcommand exits 2' 2
run_wrapper
expect_code 'no subcommand exits 2' 2

finish
