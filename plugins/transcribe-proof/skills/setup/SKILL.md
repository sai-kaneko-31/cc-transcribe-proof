---
name: setup
description: transcribe プラグインを使い始めるための AWS 側の準備を案内する。専用の S3 バケット、権限を絞った IAM ユーザー、環境変数の名前と設定、AWS が内容を保存するのを止める方法を説明し、IAM を作れない人のために、管理者へ渡す文書を出す。AWS には何も作らず、鍵も扱わない。
disable-model-invocation: true
---

# setup: 準備を案内する

このスキルは、案内と、管理者へ渡す文書を出すだけで、AWS に何も作らない。作るのは利用者か、利用者の組織の AWS 管理者で、Claude Code の外の端末で行う。

## 守ること

- IAM ユーザー、アクセスキー、バケットを、Claude のツールで作らない。`!` を付けて打つのも避ける。出力がセッションに入り、アクセスキーのシークレットが記録として手元に残るため
- `.env`、`~/.aws`、`~/.config/secrets` など、鍵の置き場を開かない
- アカウント ID、バケット名、リージョンは聞いてよい。アクセスキーとシークレットは、聞かない。利用者が貼ってきても使わず、貼らないよう伝える
- 参照ファイルは `${CLAUDE_SKILL_DIR}/references/` にある。`iam-policy.json`、`bucket-lifecycle.json`、`bucket-policy.json`、`admin-handoff.md` の 4 つ。内容を変えずに使う

## 手順

### 1. 前提を伝える

次が要る。対応する OS は macOS と Linux で、Windows は動くかを確かめていないので、未対応。

- AWS CLI v2
- jq
- ffprobe（ffmpeg に入っている）
- bash

対象の言語は日本語（ja-JP）だけ。

### 2. 誰が AWS の準備をするかを聞く

AskUserQuestion で、「自分で作れる（IAM とバケットを作る権限がある）」か「管理者に頼む」かを聞く。会社の AWS では、IAM を作れる人が別にいることが多い。

### 3. 値を決める

次を、利用者に聞く。

- リージョン（動作を確かめたのは `ap-northeast-1` だけ）
- バケット名（専用に新しく作る。グローバルで一意）
- AWS アカウント ID
- IAM ユーザー名（既定は `transcribe-plugin`）

### 4. 準備の中身を渡す

`admin-handoff.md` を Read で読み、手順を案内する。作る物は次のとおり。

- バケット: 公開ブロック 4 項目、`transcribe-skill/` 以下を 1 日で失効させるライフサイクル、TLS を使わない通信を拒否するバケットポリシー。暗号化は新しいバケットの既定のまま、バージョニングは無効のまま
- IAM ユーザー: `iam-policy.json` のポリシーだけ。Transcribe のジョブの開始・取得・削除と、`transcribe-skill/` 以下のオブジェクトの書き込み・読み取り・削除だけを許す
- アクセスキー

自分で作る利用者には、`admin-handoff.md` の手順を、利用者の端末で打つよう案内する。`<...>` の置き換え方は文書に書いてある。

管理者に頼む利用者には、4 つのファイルの `<REGION>`・`<ACCOUNT_ID>`・`<BUCKET>` を、決めた値に置き換えた版を、Write で作る。置き場所は利用者に聞き、git のリポジトリの外を勧める。管理者へ渡すのは、その 4 つのファイルとアクセスキーの受け渡しの依頼で、受け取るのは、アクセスキー ID、シークレット、バケット名、リージョン。

### 5. 環境変数

次の 4 つを、Claude Code を起動するシェルの環境に設定する。値は、利用者が自分の端末で設定する。チャットに貼らない。

- `TRANSCRIBE_AWS_ACCESS_KEY_ID`
- `TRANSCRIBE_AWS_SECRET_ACCESS_KEY`
- `TRANSCRIBE_AWS_REGION`
- `TRANSCRIBE_S3_BUCKET`

名前をプラグイン専用にしている理由は、`AWS_ACCESS_KEY_ID` などの標準の名前に、利用者のより広い権限の鍵が入っていることがあるため。標準の名前を使うと、権限を絞った意味が黙って無くなる。このプラグインは、`.env`、`~/.aws`、`AWS_PROFILE` を読まない。`.env` を使う利用者は、自分のシェルで読み込んで export する。

設定したあとは、Claude Code を、その環境変数があるシェルから起動し直す。起動のあとに足した変数は、Claude Code から見えない。

### 6. 内容の扱いを伝える

依頼主の音声を扱うときの注意を、伝える。

- AWS: 内容を、サービスの改善のために保存することがある。保存先が、使っているリージョンの外のこともある。止めるには、AWS Organizations の AI サービスのオプトアウトポリシーを使う（`admin-handoff.md` に書いてある）。止めると、サービスの提供に要るもの以外の、過去の分も消える
- Claude: 書き起こしの本文は、修正のために Claude（Anthropic）が読む。Claude Code のセッションの記録は、手元に `~/.claude/projects/` として残り、保持の日数は設定の `cleanupPeriodDays` で変える
- 依頼主との契約が、音声を AWS と Claude に渡すことを許すかは、利用者が確かめる

### 7. 確かめる

`/transcribe-proof:verify` を案内する。
