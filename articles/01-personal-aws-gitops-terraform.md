# 個人AWSをGitOpsで安全に立ち上げる ― Terraform + OIDC + CI/CD 実践ログ

> 個人のAWSアカウントを、長期キーを一切置かずにGitHubからGitOpsで管理する。
> その過程で踏んだ設計判断と、ハマった試行錯誤を学習ログとして残す。

## TL;DR

- **GitHub Actions OIDC** で AWS を操作。長期アクセスキーは GitHub にも手元にも置かない
- Terraform の **state backend / CI ロール** は「鶏卵問題」になるので、あえて Terraform の外で bash で bootstrap する
- CI は **fmt → tflint → Trivy → plan → apply** の security-first パイプライン。PR に plan をコメント、main で apply
- 実例として **S3 + KMS + IAM 最小権限** のバックアップ基盤を作り込む
- AWS Provider **v5 → v6 昇格**で breaking change を踏んだ話も書く

対象読者: Terraform / AWS の基礎はあるが、個人でも本番運用レベルの土台を作りたい中級者。

### 全体像

```
GitHub Repository (Kagayama0208/iac-aws)
        │  push / pull_request
        ▼
GitHub Actions ──(OIDCトークン)──▶ AWS STS
        │                              │ AssumeRoleWithWebIdentity
        │                              ▼
        │                     IAM Role: GitHubActions-iac-aws（一時クレデンシャル）
        ▼                              │
   terraform plan/apply ───────────────┘
        ├── State : S3 (kosuke-iac-tfstate)
        ├── Lock  : DynamoDB (iac-aws-tflock)
        └── Managed resources:
              └── keiba-db backup（S3 + KMS + IAM user）
```

---

## 1. 何を作ったか / なぜ作ったか

個人の AWS アカウントでも、リソースを手でポチポチ作ると「いつ・誰が・なぜ作ったか」がすぐ分からなくなる。そこで **すべてをコード化して GitHub から GitOps で回す** ことにした。

具体的なきっかけは、自宅の Kubernetes 上で動かしている DB（CloudNativePG / 以下 CNPG）のバックアップ先が欲しかったこと。バックアップは「自宅とは別の場所」に置きたいので、AWS の S3 を暗号化付きで用意する。これが題材の `keiba-db` プロジェクトだ。

ただ S3 を 1 個作るだけなら手作業で十分なところを、あえて以下を全部やった。学習も兼ねているので「本番でやるべきこと」を一通り通したかったからだ。

- 認証はキーレス（OIDC）
- state はリモート（S3 + DynamoDB ロック）
- 変更は必ず PR → plan レビュー → main マージで apply
- IaC のセキュリティスキャン（Trivy）を CI に組み込む

> **学んだこと**: 「個人だから雑でいい」と「個人だからこそ手を抜くと後で自分が困る」は紙一重。土台にこそコストをかける価値がある。

---

## 2. 【主役①】GitHub Actions OIDC でキーレス認証

### 何が問題か

CI から AWS を操作する一番素朴な方法は、IAM ユーザーのアクセスキーを発行して GitHub Secrets に入れることだ。だがこれは:

- **長期キーが漏れるリスク**（ログ・フォーク・誤コミット）
- **ローテーションの運用負荷**（定期的に手で差し替える必要）

がついて回る。個人開発だと「一度入れたら二度と回さない」キーが永遠に残りがちで、これは事故の温床になる。

### OIDC の仕組み

GitHub Actions は実行のたびに、自分の素性を証明する **OIDC トークン**（JWT）を発行できる。AWS 側に「GitHub を信頼する」設定をしておけば、このトークンを STS に渡して **一時クレデンシャル** を受け取れる。長期キーはどこにも存在しない。

ポイントは AWS 側の信頼ポリシー。`bootstrap/policies/trust-policy.json` がそれだ:

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::ACCOUNT_ID_PLACEHOLDER:oidc-provider/token.actions.githubusercontent.com"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
    },
    "StringLike": {
      "token.actions.githubusercontent.com:sub": "repo:Kagayama0208/iac-aws:*"
    }
  }
}
```

**ここが一番大事**: `sub` 条件で `repo:Kagayama0208/iac-aws:*` と絞っている。これがないと「GitHub Actions であれば誰でも（=他人のリポジトリでも）」このロールを引き受けられてしまう。`aud`（audience）を `sts.amazonaws.com` に固定するのも定番のガード。

> 必要に応じて `repo:Kagayama0208/iac-aws:ref:refs/heads/main` のようにブランチまで絞ると、さらに堅くできる。今回は PR でも plan を回したいので `:*` にしている。

### ワークフロー側の設定

GitHub Actions 側で必要なのは、OIDC トークンを発行する権限と、ロールを引き受けるステップだけ（`.github/workflows/terraform.yml`）:

```yaml
permissions:
  id-token: write      # OIDC トークン発行に必須
  contents: read
  pull-requests: write # PRコメント用

# ...
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
      aws-region: ${{ env.AWS_REGION }}
```

Secrets に入っているのは **ロールの ARN だけ**（秘密情報ではない識別子）で、キーは一切ない。これがキーレスの本質だ。

> **ハマった点**: `permissions: id-token: write` を書き忘れると `Error: Credentials could not be loaded` で延々こける。これはトークン発行権限がないのが原因で、ロール側の問題と勘違いして時間を溶かした。

---

## 3. 【主役②】Bootstrap の鶏卵問題をどう解くか

### なぜ Terraform で全部やらないのか

「IaC なんだから state backend も CI ロールも Terraform で作ればいい」と思うが、ここに **鶏卵問題（chicken-and-egg）** がある。`bootstrap/README.md` に簡潔にまとまっている:

- **Chicken-and-egg**: Terraform CI 用のロールは、Terraform が動く *前* に必要
- **State recursion**: state backend は自分自身の state を保存できない
- **Blast radius**: bootstrap をミスると CI 全体が壊れる。だから手動変更を強制したい

state を S3 に置くには S3 バケットが要る。だがそのバケットを Terraform で作ると、「state の保存先がまだ無い状態で state を書こうとする」という矛盾が起きる。CI ロールも同様で、Terraform を動かすロールを Terraform で作ろうとすると、最初の一回を動かす手段が無い。

### 解: Terraform の外で、べき等な bash で作る

そこで `bootstrap/` 配下に、**Terraform を動かすために最低限必要なものだけ** を作る bash スクリプトを置いた。手元の admin 権限（SSO プロファイル等）で一度だけ実行する:

```bash
export AWS_PROFILE=personal
cd bootstrap/
./01-tfstate-backend.sh   # S3 + DynamoDB
./02-github-oidc.sh       # OIDC Provider + IAM Role
```

**設計上のこだわりは「べき等性」**。何度流しても安全なように、存在チェックしてからスキップする作りになっている（`01-tfstate-backend.sh`）:

```bash
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "    Bucket already exists, skipping create."
else
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"
fi
```

state バケット自身も versioning・public access block・暗号化を有効化しておく。state ファイルは機密の塊なので、ここは手を抜けない。

OIDC 側（`02-github-oidc.sh`）も同様にべき等で、ポリシー JSON 内の `ACCOUNT_ID_PLACEHOLDER` を実アカウント ID に `sed` で差し替えてから適用する。最後に登録すべき Role ARN を親切に出力してくれる:

```bash
echo "Set this as the AWS_ROLE_ARN secret in the iac-aws GitHub repo:"
echo "  gh secret set AWS_ROLE_ARN --body \"${ROLE_ARN}\" --repo Kagayama0208/iac-aws"
```

> **学んだこと**: 「IaC = 何もかも Terraform」ではない。*Terraform を動かすための土台* は意図的に Terraform の外に置く、という線引きが大事。bootstrap だけは「手で、滅多に触らない、壊れたら全部止まる領域」と割り切る。

---

## 4. 【主役③】CI/CD パイプライン設計

`.github/workflows/terraform.yml` は 3 ジョブ構成。考え方は **「壊れるものは main に入る前に止める」** という security-first。

### ジョブ1: Lint & Security（全イベント）

```yaml
- name: terraform fmt
  run: terraform fmt -check -recursive -diff
- name: tflint
  run: |
    tflint --init
    tflint -f compact
- name: Trivy IaC scan
  uses: aquasecurity/trivy-action@v0.36.0
  with:
    scan-type: config
    severity: HIGH,CRITICAL
    exit-code: 1
```

- **fmt**: フォーマット崩れを `-check` で検出（CI では直さず、落とすだけ）
- **tflint**: recommended プリセット + AWS ruleset（`.tflint.hcl` で固定）
- **Trivy**: Terraform コードを静的解析し、HIGH/CRITICAL があれば `exit-code: 1` で CI を止める = マージをブロック

### ジョブ2: Plan（PR のときだけ）

PR では plan を流し、その結果を **PR にコメント** する。レビューで「何が変わるか」を差分として見られるのが GitOps の肝だ:

```yaml
- name: Comment plan on PR
  uses: actions/github-script@v7
  with:
    script: |
      const output = `${{ steps.plan.outputs.stdout }}`;
      const out = `#### Terraform Plan \`${{ steps.plan.outcome }}\`
      <details><summary>Show Plan</summary>

      \`\`\`
      ${output}
      \`\`\`
      </details>`;
      github.rest.issues.createComment({ /* ... */ body: out });
```

plan が長くなるので `<details>` で折りたたんでいるのが地味に効く。

### ジョブ3: Apply（main への push だけ）

```yaml
apply:
  if: github.event_name == 'push' && github.ref == 'refs/heads/main'
  environment: production   # 承認ゲートを付けられる
  steps:
    # ... OIDC で認証 ...
    - run: terraform plan -no-color -input=false -out=tfplan
    - run: terraform apply tfplan
```

`environment: production` を付けておくと、GitHub の Environment 保護ルールで **手動承認ゲート** を後付けできる。個人なら省略可だが、入れておくと「うっかり apply」を防げる。

### 安定性のための固定

```yaml
env:
  TF_VERSION: "1.9.8"   # >= 1.6.0 を満たす固定版
```

Terraform 本体は最新追従せず固定版にしている。CI が「ある日突然壊れる」のを避ける、安定性優先の判断。

> **学んだこと**: CI は「速さ」より「再現性」。バージョンを固定し、落ちる条件を明示しておくと、半年後の自分が救われる。

---

## 5. 【主役④】セキュア設計の実例（S3 + KMS + IAM 最小権限）

実際に管理しているリソース（`keiba-db.tf`）を題材に、「個人でもここまでやる」を見せる。

### S3: 多層の防御

```hcl
resource "aws_s3_bucket" "keiba-db-backup" {
  bucket           = var.keiba_db_backup_bucket_name
  bucket_namespace = "account-regional"   # ← AWS Provider v6 の新機能
}

resource "aws_s3_bucket_public_access_block" "keiba-db-backup" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

- **Public Access Block を全項目 true**: バックアップが世界に公開される事故を物理的に不可能にする
- **versioning 有効**: 誤削除・ランサムウェア対策
- **lifecycle**: `keiba-db/wals/` プレフィックスの WAL ファイルを 90 日で自動削除しコストを抑える

### KMS: 専用キーで暗号化

```hcl
resource "aws_kms_key" "keiba-db-backup" {
  description             = "KMS key for keiba-db S3 backup encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}
```

S3 のデフォルト暗号化（AES256）でなく、**専用 KMS キー（SSE-KMS）** を使う。キーローテーション有効、削除は 7 日の猶予付き。誰がいつ復号したかを CloudTrail で追える利点もある。

### IAM: 最小権限を 2 段で

CNPG がバックアップを読み書きするための専用ユーザーを作り、権限を **S3 と KMS に必要な分だけ** に絞る:

```hcl
data "aws_iam_policy_document" "keiba_db_cnpg" {
  statement {
    sid     = "S3BucketAccess"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.keiba-db-backup.arn,
      "${aws_s3_bucket.keiba-db-backup.arn}/*",
    ]
  }
  statement {
    sid     = "KMSEncryptDecrypt"
    actions = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
               "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [aws_kms_key.keiba-db-backup.arn]
  }
}
```

さらに **CI ロール側（bootstrap の `tf-permissions.json`）も最小権限** で、`Sid` ごとに責務を分割している:

| Sid | 用途 | リソース |
|---|---|---|
| `TerraformState` | state 読み書き | `kosuke-iac-tfstate` のみ |
| `TerraformLock` | ロック | `iac-aws-tflock` のみ |
| `ManageKeibaBuckets` | バケット管理 | `kosuke-keiba-db-backup-*` のみ |
| `ManageCnpgIAMUser` | ユーザー管理 | `user/keiba-db-cnpg` のみ |

「CI ロールに `AdministratorAccess` を付ける」誘惑を断ち、操作対象を ARN で名指しで縛るのがポイント。

### 機密の出力は sensitive

CNPG に渡すアクセスキーは output するが、secret 側には必ず `sensitive = true` を付ける（`outputs.tf`）:

```hcl
output "keiba_db_cnpg_secret_access_key" {
  value     = aws_iam_access_key.keiba_db_cnpg.secret
  sensitive = true   # ログ・plan 出力にマスクされる
}
```

> **学んだこと**: 最小権限は「アプリ用ユーザー」だけでなく「CI ロール自身」にも適用する。CI が全能だと、CI を乗っ取られた時点で全部終わる。

---

## 6. ハマった話: AWS Provider v5 → v6 昇格 と CI の試行錯誤

学習ログなので、きれいに動くまでの泥臭い部分も残す。`git log` を見返すと、短期間に修正コミットが密集している。

- **`fix: terraform init -upgrade を実行して v6 プロバイダ取得`**: AWS Provider を v5 → v6 に上げた。`keiba-db.tf` の `bucket_namespace = "account-regional"` は v6 で入った新しい S3 バケット命名の仕組みで、v5 のままでは使えなかった。lock ファイル（`.terraform.lock.hcl`）の更新も忘れずに commit する必要がある
- **`fix: trivyエラー` / `fix: trivy image version`**: Trivy の action バージョンや検出ルールで CI が落ち続け、何度も調整した
- **`fix: fmt error`**: `terraform fmt -check` は容赦がない。ローカルで `terraform fmt -recursive` を習慣にして解決
- **`fix: add terraform init step` / `fix bucket_name`**: ワークフローの細かい順序やバケット名のパターン調整

> **学んだこと**: メジャーバージョン昇格は「動くからいいや」で放置せず、breaking change を 1 個ずつ潰す。lock ファイルの commit 漏れは CI と手元で挙動が割れる典型的な罠。

---

## 7. まとめ

個人 AWS でも、本番品質の土台は次の原則で組める:

1. **キーレス（OIDC）**: 長期キーをそもそも作らない
2. **bootstrap の割り切り**: Terraform を動かす土台は Terraform の外で、べき等な bash で
3. **GitOps な CI/CD**: PR で plan をレビュー、main で apply、security gate でブロック
4. **最小権限の徹底**: アプリ用ユーザーにも CI ロール自身にも

正直なところ README はまだ工事中だし、環境は本番 1 つだけ（dev/stg 分割なし）と粗削りな部分も残る。だが「個人の学習プロジェクト」としては、本番運用の勘所を一通り手で通せた価値が大きかった。

### 参考リンク

- [Configuring OpenID Connect in Amazon Web Services (GitHub Docs)](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials)
- [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/settings/backends/s3)
- [Trivy: Misconfiguration Scanning](https://aquasecurity.github.io/trivy/)

---

*この記事はリポジトリ `Kagayama0208/iac-aws` の実装をもとにした学習ログです。掲載のコードは抜粋で、アカウント ID・実バケット名などの機密はマスクしています。*
