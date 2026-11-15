#!/usr/bin/env bash
# Fixture: a synthetic transcript with no recognition errors, only spoken
# style and notation variants that the corrector must not touch.
set -euo pipefail

cat > talk.transcript.txt <<'EOF'
[00:00 spk_0] えーと、会議は 3時ごろに始まって、あと 30分くらいで終わる予定です。
[00:10 spk_1] そうですね。後で資料を送ります。ご確認いただければ幸いです。
[00:20 spk_0] 資料は明日の朝までに、お送りしますね。いただいた意見は、持ち帰って検討いたします。
[00:32 spk_1] あ、はい。よろしくお願いします。
EOF
