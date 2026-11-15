#!/usr/bin/env bash
# Fixture: a synthetic transcript with a broken word that has two readings
# (トゥ枚: 2 or 10) and a sentence that stops in the middle.
set -euo pipefail

cat > talk.transcript.txt <<'EOF'
[00:00 spk_0] 打ち合わせの資料を、トゥ枚印刷しておいてください。
[00:09 spk_1] はい。それから、先方への連絡は
[00:15 spk_0] 分かりました。では、請求書の件は私が確認します。
EOF
