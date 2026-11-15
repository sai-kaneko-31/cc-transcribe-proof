---
name: verify
description: transcribe プラグインの設定が正しく動くかを、音声を送らずに確かめる。環境変数、鍵の持ち主と権限の広さ、S3 バケットの権限、Amazon Transcribe の 3 つの操作を調べ、直し方を案内する。セットアップの後と、transcribe が設定のエラーで止まったときに使う。
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/transcribe.sh verify)
---

# verify: 設定を端から端まで確かめる

利用者自身の AWS アカウントに対して、短い確認を流す。依頼主の音声は使わない。確認用の小さなファイルと、音声ではないファイルを入力にした探りのジョブを作り、終わったら消す。

## 守ること

- `.env`、`~/.aws`、`~/.config/secrets` など、鍵の置き場を開かない。環境変数の値を出力しない（有無と長さの検査は、スクリプトが値を出さずに行う）
- AWS CLI を直に打たない。AWS に触れるのは `${CLAUDE_PLUGIN_ROOT}/scripts/transcribe.sh verify` だけ
- 直すのは利用者。IAM やバケットを、Claude が作ったり変えたりしない

## 手順

### 1. 実行する

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/transcribe.sh verify
```

出力は `check <名前>: ok|NG <説明>` の行と、最後の `result=ok` か `result=ng`。終了コードは、すべて ok なら 0、NG があれば 1、環境変数の問題なら 2。

### 2. 結果を伝える

ok の項目は 1 行にまとめる。NG の項目は、次の表で原因と直し方を案内する。直し方は、`setup` の参照ファイル（ポリシーとバケットの設定）に書いてある。

| 項目 | NG の意味 | 直し方 |
| --- | --- | --- |
| `env` | 4 つの環境変数のどれかが、空か形が違う | `/transcribe:setup` の環境変数の手順。値は出さない |
| `identity` | 鍵が使えない、またはルートユーザーの鍵 | 鍵とリージョンの設定を見直す。ルートの鍵は使わず、専用の IAM ユーザーを作る |
| `broad-key` | 鍵が IAM のユーザー一覧を読める。プラグイン用のポリシーより広い権限の鍵 | プラグイン用のポリシーだけを付けた IAM ユーザーの鍵に替える |
| `bucket-rw` | 接頭辞 `transcribe-skill/` の下で、書き込み・読み取り・削除のどれかが通らない | バケット名、リージョン、ポリシーの `Objects` の文を見る |
| `bucket-outside-prefix` | 接頭辞の外にも書き込める | ポリシーの `Resource` を `transcribe-skill/*` に絞る |
| `bucket-list` | バケットの一覧を読める | ポリシーから `s3:ListBucket` を外す |
| `transcribe-start` / `transcribe-get` / `transcribe-delete` | ジョブの開始・取得・削除のどれかが通らない | ポリシーの `TranscribeJobs` の文と、リージョンを見る |

`transcribe-delete` が NG のときは、探りのジョブが AWS に残っている。出力に出たジョブ名を利用者に伝え、利用者が削除する（`aws transcribe delete-transcription-job --transcription-job-name <ジョブ名>`）。

### 3. 伝えておくこと

- 探りのジョブは、数秒で失敗する。失敗したジョブの請求は、確かめていない（AWS の文書は「文字起こしした音声の秒数」で請求すると書いている）
- すべて ok でも、鍵が正しく限られていることまでは分かるが、バケットの公開ブロック・ライフサイクル・暗号化の設定は確かめていない。`/transcribe:setup` の手順どおりに作ったかを、利用者が見る
