# Amazon Transcribe プラグインの AWS 側の準備（管理者向け）

Claude Code のプラグイン transcribe が音声の書き起こしに使う、AWS 上の物を作ってください。作るのは、専用の S3 バケット 1 つと、IAM ユーザー 1 つです。IAM ユーザーには、下のポリシーだけを付けます。完了したら、アクセスキー ID、シークレットアクセスキー、バケット名、リージョンを、依頼者へ安全な経路で渡してください。

このプラグインは、依頼者の音声をこのバケットへ一時的に置き、Amazon Transcribe で文字にします。結果を取ったあとは、置いた音声・結果・ジョブを削除します。

## 用意する値

```bash
BUCKET=<バケット名>        # 例: 組織名-transcribe-plugin
REGION=<リージョン>        # 動作を確かめたのは ap-northeast-1 だけ
ACCOUNT_ID=<AWS アカウント ID>
IAM_USER=transcribe-plugin
```

## 手順

`iam-policy.json`・`bucket-lifecycle.json`・`bucket-policy.json` は、この文書と同じ場所にあります。`<REGION>`・`<ACCOUNT_ID>`・`<BUCKET>` を、上の値に置き換えてから使います。

```bash
for f in iam-policy bucket-lifecycle bucket-policy; do
  sed -e "s/<REGION>/$REGION/g" -e "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" -e "s/<BUCKET>/$BUCKET/g" "$f.json" > "$f.filled.json"
done
```

1. バケットを作る。リージョンが `us-east-1` のときは、`--create-bucket-configuration` を付けない

    ```bash
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --create-bucket-configuration "LocationConstraint=$REGION"
    ```

2. 公開を禁止する

    ```bash
    aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    ```

3. 置いた物を 1 日で失効させる（プラグインが途中で止まったときの保険）

    ```bash
    aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration file://bucket-lifecycle.filled.json
    ```

4. TLS を使わない通信を拒否する

    ```bash
    aws s3api put-bucket-policy --bucket "$BUCKET" --policy file://bucket-policy.filled.json
    ```

5. IAM ユーザーを作り、ポリシーを付ける

    ```bash
    aws iam create-user --user-name "$IAM_USER"
    aws iam put-user-policy --user-name "$IAM_USER" --policy-name transcribe-plugin --policy-document file://iam-policy.filled.json
    ```

6. アクセスキーを作る。出力のシークレットアクセスキーは、このとき 1 度しか表示されません。チャット、メール、チケットに貼らず、組織の秘密の受け渡しの手段で渡してください

    ```bash
    aws iam create-access-key --user-name "$IAM_USER"
    ```

バケットの暗号化は、新しいバケットの既定（SSE-S3）のままにします。バージョニングは有効にしません（有効にすると、削除が削除マーカーを置くだけになり、音声が古い版として残ります。ライフサイクルは古い版も 1 日で消しますが、既存のバケットを使うときも、バージョニングの無いバケットを選んでください）。

## このポリシーが許すこと

- Amazon Transcribe のジョブの開始・取得・削除（指定リージョンの、このアカウントの、名前が `tsk-` で始まるジョブだけ。プラグインが付ける名前）
- バケットの `transcribe-skill/` 以下への、オブジェクトの書き込み・読み取り・削除

バケットの一覧、`transcribe-skill/` の外、ほかのサービスは許しません。

## 任意: AWS が内容を改善に使うのを止める

AWS の AI サービスは、内容をサービスの改善のために保存することがあります。止めるには、AWS Organizations の AI サービスのオプトアウトポリシーを使います。止めると、サービスの提供に要るもの以外の、過去の分も消えます。依頼主の音声を扱うなら、検討してください。

## 確認

依頼者が Claude Code で `/transcribe-proof:verify` を実行します。環境変数、鍵の持ち主と権限の広さ、バケットの権限、Transcribe の 3 つの操作が確かめられます。
