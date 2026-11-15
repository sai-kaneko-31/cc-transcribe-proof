#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034
# (variables come from lib.sh)
#
# Consistency checks across the plugin's files: the reference JSON, the skills'
# permissions and the numbers that the skills, the agent and the script must
# agree on. These checks run no AWS call and need no fake.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq > /dev/null 2>&1 || {
  echo 'SKIP test_plugin_files.sh: jq is not installed, so the reference JSON is unchecked'
  exit 0
}

plugin="$root/plugins/transcribe"
refs="$plugin/skills/setup/references"

frontmatter() { # prints the YAML block between the first two --- lines
  awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$1"
}

has() { # label file fixed-string
  if grep -q -F -e "$3" "$2"; then ok "$1"; else bad "$1: '$3' not in $2"; fi
}

# ---- reference JSON ----
for f in iam-policy bucket-lifecycle bucket-policy; do
  if jq empty "$refs/$f.json" 2> /dev/null; then ok "$f.json is valid JSON"; else bad "$f.json is not valid JSON"; fi
done

n=$(jq '.Statement | length' "$refs/iam-policy.json")
[ "$n" = '2' ] && ok 'the IAM policy has 2 statements' || bad "the IAM policy has $n statements"
actions=$(jq -r '.Statement[].Action | if type == "array" then .[] else . end' "$refs/iam-policy.json" | sort | tr '\n' ' ')
want='s3:DeleteObject s3:GetObject s3:PutObject transcribe:DeleteTranscriptionJob transcribe:GetTranscriptionJob transcribe:StartTranscriptionJob '
[ "$actions" = "$want" ] && ok 'the IAM policy allows exactly the six actions the script uses' || bad "IAM actions: $actions"
if jq -e '.Statement[] | select(.Effect != "Allow")' "$refs/iam-policy.json" > /dev/null; then bad 'the IAM policy has a non-Allow statement'; else ok 'the IAM policy only allows'; fi
if jq -r '.Statement[].Action | if type == "array" then .[] else . end' "$refs/iam-policy.json" | grep -q '\*'; then bad 'the IAM policy has a wildcard action'; else ok 'the IAM policy has no wildcard action'; fi
prefix=$(sed -n "s/^readonly KEY_PREFIX='\([^']*\)'.*/\1/p" "$wrapper")
[ -n "$prefix" ] && ok "the script's key prefix is $prefix" || bad 'could not read KEY_PREFIX from the script'
s3res=$(jq -r '.Statement[] | select(.Action | tostring | test("s3:")) | .Resource' "$refs/iam-policy.json")
[ "$s3res" = "arn:aws:s3:::<BUCKET>/$prefix/*" ] && ok 'the S3 statement is limited to the script prefix' || bad "S3 resource is $s3res"
trres=$(jq -r '.Statement[] | select(.Action | tostring | test("transcribe:")) | .Resource' "$refs/iam-policy.json")
[ "$trres" = 'arn:aws:transcribe:<REGION>:<ACCOUNT_ID>:transcription-job/*' ] && ok 'the Transcribe statement is limited to jobs of one account and region' || bad "Transcribe resource is $trres"

lp=$(jq -r '.Rules[0].Filter.Prefix' "$refs/bucket-lifecycle.json")
[ "$lp" = "$prefix/" ] && ok 'the lifecycle rule covers the script prefix' || bad "lifecycle prefix is $lp"
[ "$(jq '.Rules[0].Expiration.Days' "$refs/bucket-lifecycle.json")" = '1' ] && ok 'the lifecycle rule expires objects after 1 day' || bad 'lifecycle expiration is not 1 day'
[ "$(jq '.Rules[0].AbortIncompleteMultipartUpload.DaysAfterInitiation' "$refs/bucket-lifecycle.json")" = '1' ] && ok 'the lifecycle rule aborts incomplete uploads after 1 day' || bad 'multipart abort is not 1 day'
[ "$(jq -r '.Statement[0].Condition.Bool["aws:SecureTransport"]' "$refs/bucket-policy.json")" = 'false' ] && ok 'the bucket policy denies requests without TLS' || bad 'bucket policy does not deny non-TLS'

placeholders=$(cat "$refs"/*.json "$refs/admin-handoff.md" | grep -o '<[A-Z_]*>' | sort -u | tr '\n' ' ')
[ "$placeholders" = '<ACCOUNT_ID> <BUCKET> <REGION> ' ] && ok 'the references use only the three placeholders' || bad "placeholders: $placeholders"

# ---- permissions in the skills ----
for s in transcribe correct verify setup; do
  file="$plugin/skills/$s/SKILL.md"
  fm=$(frontmatter "$file")
  [ -n "$fm" ] && ok "skill $s has frontmatter" || bad "skill $s has no frontmatter"
  tools=$(printf '%s\n' "$fm" | sed -n 's/^allowed-tools: //p')
  rest=$tools
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    rest=${rest/"$entry"/}
    case "$entry" in
      'Bash(${CLAUDE_PLUGIN_ROOT}/scripts/transcribe.sh estimate *)' | 'Bash(${CLAUDE_PLUGIN_ROOT}/scripts/transcribe.sh apply *)' | 'Bash(${CLAUDE_PLUGIN_ROOT}/scripts/transcribe.sh verify)') ok "skill $s pre-approves only $entry" ;;
      *) bad "skill $s pre-approves $entry" ;;
    esac
  done < <(printf '%s\n' "$tools" | grep -o 'Bash([^)]*)')
  [ -z "${rest// /}" ] && ok "skill $s lists nothing but Bash entries" || bad "skill $s has other allowed-tools text: $rest"
  case "$s" in
    transcribe | verify | setup)
      printf '%s\n' "$fm" | grep -q '^disable-model-invocation: true$' && ok "skill $s is user-invoked only" || bad "skill $s can be invoked by the model"
      ;;
  esac
done
if grep -l -e 'transcribe.sh run' "$plugin"/skills/*/SKILL.md | head -n 1 | grep -q .; then ok 'the run command is described in a skill'; else bad 'no skill describes run'; fi
if frontmatter "$plugin/skills/transcribe/SKILL.md" | grep -q 'transcribe.sh run'; then bad 'run is pre-approved in the transcribe skill'; else ok 'run is not pre-approved (Claude Code asks before audio leaves the machine)'; fi

# every script subcommand named in a skill exists in the script
for sub in $(grep -h -o 'transcribe\.sh [a-z-]*' "$plugin"/skills/*/SKILL.md | awk '{print $2}' | sort -u); do
  if grep -q -E "^  $sub\) cmd_" "$wrapper"; then ok "subcommand $sub exists in the script"; else bad "subcommand $sub is named in a skill but missing in the script"; fi
done

# ---- the corrector agent ----
afm=$(frontmatter "$plugin/agents/corrector.md")
[ "$(printf '%s\n' "$afm" | sed -n 's/^tools: //p')" = 'Read' ] && ok 'the corrector can only Read' || bad 'the corrector tools are not exactly Read'
printf '%s\n' "$afm" | grep -q -e '^disallowedTools' -e '^permissionMode' -e '^hooks' && bad 'the corrector sets fields that plugin agents ignore' || ok 'the corrector sets no ignored fields'

# ---- numbers that must agree ----
has 'the agent states the new-text length rule' "$plugin/agents/corrector.md" 'old の 3 倍と 20 文字'
has 'the script uses the same length rule' "$wrapper" '(.old | length) * 3 + 20'
has 'the transcribe skill states the duration limit' "$plugin/skills/transcribe/SKILL.md" '120 分'
has 'the script has the same duration limit' "$wrapper" 'readonly MAX_SECONDS=7200'
has 'the transcribe skill states the size limit' "$plugin/skills/transcribe/SKILL.md" '2 GB'
has 'the script has the same size limit' "$wrapper" 'readonly MAX_BYTES=2000000000'
has 'the skill names the default speaker maximum like the script' "$plugin/skills/transcribe/SKILL.md" '省略すると 10'
has 'the script has that default' "$wrapper" 'readonly DEFAULT_SPEAKERS=10'

finish
