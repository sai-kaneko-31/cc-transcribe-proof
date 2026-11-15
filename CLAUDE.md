# transcribe

音声と動画を Amazon Transcribe で日本語に書き起こし、誤認識だけを別の Claude が直す Claude Code のプラグイン。1 つのリポジトリがマーケットプレイスとプラグインを兼ねる。利用者は、作者以外の人を前提にする。作者の環境（広い権限の鍵が標準の環境変数にある、など）に依存する手順を、スキルや README に書かない。

## 構成

- `.claude-plugin/marketplace.json`: マーケットプレイスの定義。version は書かない
- `plugins/transcribe/.claude-plugin/plugin.json`: プラグインの定義。version はここにだけ書く
- `plugins/transcribe/scripts/transcribe.sh`: AWS に触れる唯一の入口。`estimate`・`run`・`verify`・`apply` の 4 つ。bash 3.2（macOS の既定）で動くように書く
- `plugins/transcribe/skills/{transcribe,correct,verify,setup}/SKILL.md`: スキル。`setup/references/` に、IAM のポリシー、バケットの設定、管理者向けの文書
- `plugins/transcribe/agents/corrector.md`: 修正役。`tools` は `Read` だけ
- `plugins/transcribe/evals/`: 誤認識の修正の評価ケース
- `tests/`: スクリプトとファイル間の整合のテスト

## 変えてはいけない前提

- `run` を、スキルの `allowed-tools` に入れない。Claude Code の確認が、音声が手元を出る前の最後の確認になる。`test_plugin_files.sh` が見る
- 事前承認してよいのは、`estimate`・`apply`・`verify` だけ。形は `Bash(${CLAUDE_PLUGIN_ROOT}/scripts/transcribe.sh <サブコマンド> *)`
- 修正役に Read 以外の道具を持たせない。本文を書き換えられるのは `apply` だけで、`apply` は、形が正しく、行の中にちょうど 1 回ある文字列の編集だけを当てる
- 書き起こしの本文は、AWS の後片付けが済むまで、標準出力へ出さず、モデルの文脈へ入れない
- AWS の呼び出しはすべて `--region` と、S3 は `--expected-bucket-owner` を付ける。環境は、スクリプトの冒頭で捨てる

## スクリプトを変えるとき

- 先にテストを書き、落ちるのを見てから直す。テストは、偽の `aws`・`ffprobe`・`sleep` を PATH の先頭に置いて回す（`tests/lib.sh`）。偽の物へ渡す設定は、環境変数ではなく、`$state` のファイルで切り替える（環境を捨てるため、テスト専用の環境変数は届かない）
- 後片付けの対象を覚える変数を、コマンド置換（`$(...)`）の中で更新しない。親のシェルに残らず、AWS に物が残る
- テストは bash 5 と、macOS の `/bin/bash`（3.2）の両方で回す
- 検査を足したら、その検査を壊しても落ちることを、1 つ壊して確かめる（全部通ったときこそ、テストが何も見ていないことを疑う）
- 上限（長さ 120 分、大きさ 2 GB、`new` の長さの規則）は定数で、環境変数では変えられない。SKILL.md・修正役・スクリプトに同じ数字がある。`test_plugin_files.sh` が揃いを見る
- `jq`・`ffprobe` が無い環境では、一部のテストが SKIP になる。SKIP した経路は、確かめていない

## SKILL.md と README を変えるとき

- 担当範囲の説明は、各 SKILL.md の description、README の「何をするか」、plugin.json の description にある。範囲を変えたら全部揃える
- 手順は現在形で書く。作者個人の仕組みの名前、経緯、チケット番号、別のリポジトリ固有の情報を書かない
- 公式のドキュメントで確かめていないことは、確かめていないと書く（失敗したジョブの請求、ap-northeast-1 以外、実録音の精度など）

## リリース

- スキルやスクリプトの中身を変えて公開するときは、plugin.json の version を上げる。上げないと、マーケットプレイスから入れた利用者は更新を受け取らない
- version を上げるときは、plugin.json だけを変える単独のコミットにする
- 検証は、リポジトリ直下で `claude plugin validate .`
- PR は merge commit でマージする

## 評価ケース

- 1 ケース 1 フォルダ。`case.yaml` と `scaffold.sh`。入力は、手で書いた合成の書き起こしで、依頼主の名前や実際の会話を入れない
- 実行: `cd plugins/transcribe && claude plugin eval . --case <ケース名> --scaffold --allow-tools Write Bash --max-cost-usd <上限> --no-publish`。モデルを動かすので料金がかかる。実行の前に、見積もりを持ち主へ伝える
- 結果は `plugins/transcribe/evals/results/` に出る。git には入らない
- 採点の正規表現は、手で書いた理想の答えを通して、通ることを確かめる。何もしない答えを通して、落ちることも確かめる
- 修正の評価は、正解を見せない別の文脈で回す。同じ会話で正解を見たあとだと、結果が引きずられる

## リポジトリに入れないもの

- 実際の鍵、AWS のアカウント ID、バケット名、依頼主の音声、個人情報、他人の文章
- テスト用の鍵の形の文字列は、実行時に組み立てる（`tests/lib.sh` が例）
- 音声の見本は、バイナリで置かない。台本と生成スクリプトで置く
