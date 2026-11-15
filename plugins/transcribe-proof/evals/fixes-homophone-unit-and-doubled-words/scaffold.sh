#!/usr/bin/env bash
# Fixture: a synthetic Japanese transcript with four recognition errors
# (a homophone, a unit, a repeated sentence, a doubled character).
set -euo pipefail

cat > talk.transcript.txt <<'EOF'
[00:00 spk_0] 本日はお時間をいただきありがとうございます。請求書の入力作業の自動化についてご相談です。
[00:12 spk_1] はい、よろしくお願いします。今は月に 1,250点ほどの請求書を手で入力しています。
[00:25 spk_0] ありがとうございます。まず研修の流れを確認させてください。納品のあとに、先方が確認して、問題がなければ請求書を出す形ですか。
[00:41 spk_1] そうです。納品のあとに確認が入って、問題がなければ請求書を出します。確認します。確認します。
[00:55 spk_0] 分かりました。入力した内容は、どこに保存していますか。
[01:03 spk_1] 共有のフォルダに保存しています。個人人情報が入る書類もあるので、アクセスは限っています。
EOF
