# 何もない状態から作る個人AWS基盤 ― 構築手順と「考えた順番」の記録

> S3 を 1 個作りたいだけだったのに、気づけば OIDC も CI/CD も組んでいた。
> この記事は、**何もない状態から完成まで** を作った順に並べ、各ステップで **何を・なぜその順番で考えたか** を残す「思考の作業ログ」だ。

## TL;DR

- 「個人の AWS をコードで管理する」基盤を、**時系列の構築順**（構想 → bootstrap → Terraform 本体 → リソース → CI/CD → 運用）で辿る
- 各ステップで立ち止まって考えたことを `> 💭` で明示する。**結論より「考える順番」が主役**
- 詰まった箇所（鶏卵問題・Provider v5→v6 昇格・Trivy・`fmt`）も時系列で振り返る
- 個々の仕組みの深掘りは [01-personal-aws-gitops-terraform.md](01-personal-aws-gitops-terraform.md)、全体の地図は [00-terraform-aws-project-tour.md](00-terraform-aws-project-tour.md) に譲る。本記事は **「どう作っていったか」** に集中する

対象読者: Terraform / AWS / GitHub の基礎はあり、**同じものを自分の手で組み立てたい中級者**。

### 完成形（先にゴールを見る）

作った順を追う前に、辿り着く先を一枚で押さえておく。

```
GitHub Repository (Kagayama0208/iac-aws)
        │  push / pull_request
        ▼
GitHub Actions ──(OIDCトークン)──▶ AWS STS
        │                              │ AssumeRoleWithWebIdentity
        ▼                              ▼
   terraform plan/apply ◀──── IAM Role: GitHubActions-iac-aws（一時クレデンシャル）
        ├── State : S3 (kosuke-iac-tfstate) + Lock : DynamoDB (iac-aws-tflock)
        └── 管理対象リソース:
              ├── keiba-db backup（S3 + KMS + IAM）
              └── personal-blog images（S3 + IAM）
```

この図の**左下から右上へ**――つまり「土台 → 認証 → 自動化 → 中身のリソース」の順に、実際は組み上げていった。以下、その順で辿る。

---

## STEP 0: 構想 ― 手を動かす前に「どこまでやるか」を決める

### 💭 まず考えたこと

きっかけは具体的だった。自宅の Kubernetes で動かしている DB（CloudNativePG、以下 CNPG）の **バックアップ先** が欲しい。自宅とは別の場所に置きたいので、AWS の S3 を暗号化付きで用意したい。これが題材の `keiba-db` だ。

ここで最初の分岐点が来る。**「S3 を 1 個作る」だけなら、AWS の管理画面を 5 分ポチポチすれば終わる。** わざわざ Terraform を持ち出す必要はない。

> 💭 **ここで考えたこと**:
> 「手作業 vs コード化」は、規模ではなく **"後で困るか"** で決める。個人プロジェクトでも、半年後の自分は「このバケット、いつ・なぜ・どんな設定で作ったんだっけ?」を必ず忘れる。手で作ると、その記録がどこにも残らない。
> だから今回は **あえて全部コード化し、本番運用の作法を一通り通す** ことにした。学習も兼ねているので、ここで手を抜かないと決めた。

決めた「やること」は4つ:

- 認証はキーレス（OIDC、長期キーを作らない）
- state はリモート（S3 + DynamoDB ロック）
- 変更は必ず PR → plan レビュー → main マージで apply
- IaC のセキュリティスキャン（Trivy）を CI に入れる

この「最初にゴールの厳しさを決める」一手が、以降のすべての順番を規定した。

---

## STEP 1: いきなり詰まる ―「鶏が先か、卵が先か」

### 💭 最初の一歩で手が止まった

「じゃあ Terraform を書こう」と `backend.tf` に着手した瞬間に止まった。

state を S3 に置きたい。**ではその S3 バケットは誰が作る?** Terraform で作ろうとすると、「state の保存先がまだ無い状態で state を書く」という矛盾が起きる。CI を動かす IAM ロールも同じで、**Terraform を動かすロールを Terraform で作る** には、最初の一回を動かす手段が要る。これが鶏卵問題（chicken-and-egg）だ。

> 💭 **ここで考えたこと**:
> 「IaC なんだから何もかも Terraform で」と思い込んでいたが、それは無理だと気づいた。**Terraform を *動かすための* 土台は、Terraform の *外* に置く** しかない。
> ここで「bootstrap（土台づくり）」と「本体（アプリのリソース）」を、頭の中で別レイヤーに切り分けた。この線引きさえ決まれば、あとは順番に積むだけになる。

なぜ Terraform でやらないかを3点で割り切った（`bootstrap/README.md` にも残してある）:

- **鶏卵問題**: Terraform CI 用ロールは Terraform が動く *前* に必要
- **state の自己参照**: state backend は自分自身の state を保存できない
- **影響範囲（blast radius）**: bootstrap をミスると CI 全体が壊れる → むしろ手動変更を強制したい

設計上の「なぜ」の深掘りは [01 の §3](01-personal-aws-gitops-terraform.md) に書いた。ここでは **「外に切り出すと決めた」という判断そのもの** が、構築順を決めた転換点だった、とだけ押さえておく。

---

## STEP 2: 手で土台を作る（bootstrap）

線引きが決まったので、まず **手で一度だけ** 土台を作る。`bootstrap/` 配下の bash スクリプトを、手元の admin 権限（SSO プロファイル）で実行する。

```bash
export AWS_PROFILE=personal
cd bootstrap/
./01-tfstate-backend.sh   # ① state 用 S3 + DynamoDB
./02-github-oidc.sh       # ② OIDC Provider + IAM Role
```

### ① state backend（`01-tfstate-backend.sh`）

`kosuke-iac-tfstate`（S3）と `iac-aws-tflock`（DynamoDB）を作る。state バケット自身も versioning・public access block・暗号化まで有効にする。state ファイルは機密の塊なので、土台といえど手を抜かない。

```bash
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "    Bucket already exists, skipping create."
else
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"
fi
```

> 💭 **ここで考えたこと（べき等性）**:
> bootstrap は「滅多に触らないが、壊れたら全部止まる」領域。だから **何度流しても安全** であることを最優先にした。存在チェックしてから作る作りにしておけば、途中で失敗して再実行しても事故らない。「一発勝負のスクリプト」にしないのが、手作業領域を安全に保つコツだ。

### ② OIDC Provider と CI ロール（`02-github-oidc.sh`）

GitHub Actions が AWS を **キーなしで** 操作できるようにする。ポリシー JSON 内の `ACCOUNT_ID_PLACEHOLDER` を実アカウント ID に `sed` で差し替えてから適用する。肝は信頼ポリシー（`trust-policy.json`）の絞り込み:

```json
"Condition": {
  "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
  "StringLike":  { "token.actions.githubusercontent.com:sub": "repo:Kagayama0208/iac-aws:*" }
}
```

> 💭 **ここで考えたこと（絞り込み）**:
> `sub` を `repo:Kagayama0208/iac-aws:*` に縛らないと、「GitHub Actions であれば誰でも（＝他人のリポジトリからでも）」このロールを引き受けられてしまう。**信頼の入口は最初に最大限狭めておく** ――後から緩めるのは簡単だが、緩い状態に気づくのは大抵インシデントの後だ。
> OIDC の仕組み自体の解説は [01 の §2](01-personal-aws-gitops-terraform.md) に譲る。

### ③ ロール ARN を Secret に登録

スクリプトが最後に親切にコマンドを出力してくれるので、それを実行する:

```bash
gh secret set AWS_ROLE_ARN --body "<出力されたRole ARN>" --repo Kagayama0208/iac-aws
```

GitHub に渡すのは **ロールの ARN だけ**。これは秘密情報ではなく単なる識別子で、アクセスキーは一切置かない。これがキーレスの本質だ。

> ⚠️ **詰まった点**: ワークフロー側で `permissions: id-token: write` を書き忘れると `Error: Credentials could not be loaded` で延々こける。トークン *発行* 権限の問題なのに、ロール *側* の設定を疑って時間を溶かした。詰まったら「トークンを出す側」と「受け取る側」を分けて切り分けるとよい。

---

## STEP 3: Terraform 本体の骨格を置く

土台ができたので、ようやく Terraform 本体に戻れる。ここでも **いきなりリソースを書かない**。先に「器」を固める。

順番はこうした:

```
versions.tf   → providers.tf → backend.tf      → variables.tf
（道具の固定）  （どこに作るか）  （STEP2の土台を指す）（入力の型）
```

```hcl
# versions.tf ― 道具のバージョンを固定
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
```

```hcl
# backend.tf ― STEP2 で手作りしたバケットをここで指す
terraform {
  backend "s3" {
    bucket         = "kosuke-iac-tfstate"
    key            = "iac-aws/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "iac-aws-tflock"
    encrypt        = true
  }
}
```

```hcl
# variables.tf ― バケット名は機密扱い
variable "keiba_db_backup_bucket_name" {
  type      = string
  sensitive = true
}
```

> 💭 **ここで考えたこと（順番）**:
> リソース（中身）を書く前に、**「どの道具で・どこに・どんな入力で作るか」という器を先に確定** させる。器が揺れたまま中身を書くと、後で全部やり直しになる。
> `backend.tf` が STEP2 で手作りした S3/DynamoDB をそのまま指している点に注目してほしい。**土台 → 器 → 中身** という依存の向きが、そのまま構築の順番になっている。
> バケット名を `sensitive = true` にしたのは、plan やログに実名を晒さないため。「機密になり得る入力は、最初の定義時点で sensitive」と決め打ちにしておくと迷わない。

---

## STEP 4: 最初のリソースを書く（keiba-db.tf）

ここからが「中身」。最初の題材は当初の目的だった CNPG バックアップ用の S3 だ。重要なのは **書いた順番＝安全性の積み上げ順** になっていること。

```
S3バケット → public access block → versioning → KMS鍵 → SSE-KMS → lifecycle → IAMポリシー
```

```hcl
resource "aws_s3_bucket" "keiba-db-backup" {
  bucket           = var.keiba_db_backup_bucket_name
  bucket_namespace = "account-regional"   # ← AWS Provider v6 の命名方式
}

resource "aws_s3_bucket_public_access_block" "keiba-db-backup" {
  bucket                  = aws_s3_bucket.keiba-db-backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

> 💭 **ここで考えたこと（"作る" で止めない）**:
> `aws_s3_bucket` を 1 行書いた時点で「バケットはできる」。でもそれは **完成ではない**。バックアップが世界に公開される事故を物理的に潰す public access block、誤削除に備える versioning、専用 KMS 鍵での暗号化――**ここまでで初めて 1 セット** だと考えた。
> 手作業だと「とりあえず作って、設定は後で」になりがちで、その「後で」は来ない。コードに積んでおけば毎回・確実に適用される。これが STEP0 で「コード化する」と決めた効能そのものだ。

暗号化は **専用の KMS 鍵（SSE-KMS）** を使い、ローテーション有効・削除7日猶予にした。lifecycle はプレフィックスごとに保持期間を変えている:

```hcl
rule { id = "expire-old-wal"  filter { prefix = "keiba-db/wals/" }  expiration { days = 30 } }
rule { id = "expire-old-base" filter { prefix = "keiba-db/base/" }  expiration { days = 90 } }
```

WAL（更新ログ）は溜まりやすいので 30 日、ベースバックアップは 90 日と、データの性質に応じてコストと保全のバランスを変えた。

IAM は CNPG 用の最小権限ポリシーを組む。ここで 1 つ判断がある:

```hcl
# 既存 user は手動管理のまま、attach だけ Terraform で
resource "aws_iam_user_policy_attachment" "keiba_db_backup" {
  user       = "keiba-db-backup"   # 既存 user 名を直書き（Terraform 管理外）
  policy_arn = aws_iam_policy.keiba_db_backup.arn
}
```

> 💭 **ここで考えたこと（既存資産との折り合い）**:
> keiba-db のユーザーは bootstrap 以前から手で作って運用していた。これを Terraform 管理に取り込む（import する）か迷ったが、**「ポリシーの attach だけ Terraform、ユーザー本体は手動のまま」** という折衷にした。すべてを一気にコード化しようとすると移行で事故る。**境界を引いて段階的に取り込む** ほうが安全だ。
> 最小権限ポリシーの具体的な組み方は [01 の §5](01-personal-aws-gitops-terraform.md) に詳しい。

---

## STEP 5: 2 個目で「設計を再利用しつつ、判断を変える」

`keiba-db.tf` が動いたので、2 つ目の題材 `personal-blog.tf`（ブログ画像置き場）に進む。基本構造は keiba-db を **写経** すればいい。S3 → public access block → versioning → 暗号化 → lifecycle → IAM、という骨格は同じだ。

ただし、考えなしにコピペはしない。

```hcl
# 画像配信用途のため CMK は使わず SSE-S3(AES256)を採用。AWS-0132 を意図的に抑制。
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "blog-images" {
  bucket = aws_s3_bucket.blog-images.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
```

> 💭 **ここで考えたこと（同じパターンでも判断は使い分ける）**:
> keiba-db は **専用 KMS 鍵**にした。だが personal-blog は「ブログに載せる画像」で、機密性は低く、むしろ配信のしやすさが大事。ここに CMK を持ち出すのは過剰で、鍵管理コストだけが増える。**用途に合わせて SSE-S3（AES256）に格下げ** した。
> ただし Trivy は「CMK を使え（AVD-AWS-0132）」と警告してくる。これは **正しい指摘だが、今回は意図的に外す** 判断なので、`#trivy:ignore` で理由付きで抑制した。スキャナを黙らせるのではなく、「なぜ無視するか」をコードに残すのがポイント。

もう一つの非対称な判断がユーザーまわりだ。keiba-db は既存ユーザーに attach だけだったが、ブログ用は **専用ユーザーを新規作成し、アプリ用のアクセスキーまで発行** する:

```hcl
resource "aws_iam_user" "blog_images"       { name = "personal-blog-images" }
resource "aws_iam_access_key" "blog_images" { user = aws_iam_user.blog_images.name }
```

発行したシークレットは output するが、必ず `sensitive` を付ける（`outputs.tf`）:

```hcl
output "blog_images_secret_access_key" {
  value     = aws_iam_access_key.blog_images.secret
  sensitive = true   # plan / ログでマスクされる
}
```

> 💭 **ここで考えたこと（非対称を許す）**:
> 「2 つの S3 は似ているから完全に同じ作りにすべき」と揃えたくなるが、**前提（既存ユーザーの有無・機密度）が違えば作りも変えていい**。無理に統一しないこと自体が設計判断だ。

---

## STEP 6: CI/CD で自動化する

リソースが手元で書けたら、最後に **「人がコンソールを触らずに回る」仕組み** に載せる。`.github/workflows/terraform.yml` を 3 ジョブで組んだ。

```
lint（全イベント） → plan（PRのみ）→ apply（main push のみ）
```

設計思想は **「壊れるものは main に入る *前* に止める」** という security-first。

```yaml
# ジョブ1: lint ― fmt / tflint / Trivy。HIGH/CRITICAL は exit-code:1 で止める
- name: terraform fmt
  run: terraform fmt -check -recursive -diff
- name: Trivy IaC scan
  uses: aquasecurity/trivy-action@v0.36.0
  with: { scan-type: config, severity: HIGH,CRITICAL, exit-code: 1 }
```

```yaml
# ジョブ3: apply ― main への push だけ
apply:
  if: github.event_name == 'push' && github.ref == 'refs/heads/main'
  environment: production   # 承認ゲートを後付けできる
```

> 💭 **ここで考えたこと（順番＝防御の段階）**:
> ジョブの並び順そのものが防御線になっている。**まず lint で機械的なミスとセキュリティ違反を弾き、PR で plan を人がレビューし、main に入って初めて apply**。安いチェックを前に、影響の大きい操作を後ろに置く。
> `environment: production` を付けたのは、将来「うっかり apply」を承認ゲートで止められる余地を残すため。個人なら省略可だが、入口だけ作っておく。
> CI の中身の詳細（PR への plan コメント、OIDC 認証ステップ）は [01 の §4](01-personal-aws-gitops-terraform.md) に書いた。

TF 本体のバージョンは固定にした:

```yaml
env:
  TF_VERSION: "1.9.8"   # >= 1.6.0 を満たす固定版
```

> 💭 **ここで考えたこと（再現性 > 最新）**:
> CI は「速さ」や「最新さ」より **再現性**。`latest` 追従にすると、ある日 Terraform 側の変更で何もしていないのに CI が壊れる。固定しておけば、半年後の自分が同じ結果を得られる。

---

## STEP 7: 動かして PR → plan → apply を一周する

ここまでで仕組みが揃ったので、実際の運用ループを一周させる。

```
  .tf を編集 → git push / PR
        │
        ▼  GitHub Actions が起動
   lint（fmt/tflint/Trivy）→ plan を PR にコメント
        │  レビューで差分を確認 → main にマージ
        ▼
   apply（OIDC でキーレス認証 → terraform apply）
        │
        ▼  AWS に S3 / KMS / IAM が実際に作られる
```

> 💭 **ここで考えたこと（運用に乗った瞬間）**:
> ここまで来て初めて「**人が AWS 管理画面を手で触る場面が、最初の bootstrap を除いてゼロ**」になった。変更はすべて PR に乗り、「いつ・誰が・なぜ変えたか」が Git の履歴に残る。STEP0 で「後で困らないために」と決めたゴールに、ここで到達した。

---

## ハマりログ（時系列で振り返る）

学習ログなので、きれいに動くまでの泥臭い部分も残す。`git log` を見返すと、短期間に `fix:` コミットが密集している。

| 詰まった所 | 何が起きたか | どう抜けたか |
|---|---|---|
| **Provider v5 → v6 昇格** | `bucket_namespace = "account-regional"` は v6 の新方式で、v5 では使えずエラー | `terraform init -upgrade` で v6 を取得。`.terraform.lock.hcl` の更新を **commit し忘れる** と CI と手元で挙動が割れる罠も踏んだ |
| **Trivy** | action バージョンや検出ルールで CI が落ち続けた | バージョンを固定し、意図的に外す指摘は `#trivy:ignore` に理由付きで明記（STEP5） |
| **`terraform fmt -check`** | フォーマット崩れで容赦なく落ちる | ローカルで `terraform fmt -recursive` を習慣化 |
| **state に未登録の既存バケット** | 手で先に作っていた S3 が state に無く plan が衝突 | workflow に `terraform import ... 2>/dev/null \|\| true` ステップを足し、初回だけ取り込んでから plan する形にした |

> 💭 **ここで考えたこと（昇格は1個ずつ潰す）**:
> メジャーバージョン昇格は「動くからいいや」で放置せず、breaking change を 1 個ずつ潰す。とくに lock ファイルの commit 漏れは「手元では通るのに CI で落ちる」典型で、原因に気づくまで一番時間を食った。

---

## まとめ ― 構築順から学んだ「考える順番」

この基盤は、結局のところ **次の順番で考えると迷子にならない** ことを教えてくれた。

1. **ゴールの厳しさを先に決める**（STEP0）― どこまでやるかを最初に握る
2. **土台を外に切り出す**（STEP1〜2）― Terraform を動かす前提は Terraform の外で、べき等な手作業で
3. **器を固めてから中身**（STEP3〜5）― 道具・場所・入力を確定してからリソースを積む。安全側設定までで 1 セット
4. **最後に自動化と運用**（STEP6〜7）― 手で一周できたものを CI/CD に載せる

依存の向き（土台 → 器 → 中身 → 自動化）が、そのまま **作る順番** であり **考える順番** でもある。`.tf` ファイルの数に圧倒されても、この順で 1 段ずつ積めば必ず組み上がる。

正直まだ粗削りで、環境は本番 1 つだけ（dev/stg 分割なし）だし README も工事中だ。それでも「個人の学習プロジェクト」として、本番運用の勘所を **手で一通り通せた** 価値は大きかった。

---

## 次に読む

- **[00-terraform-aws-project-tour.md](00-terraform-aws-project-tour.md)** ― 完成したリポジトリを **ディレクトリ構造** から俯瞰する地図記事。「どのファイルが何の役割か」を先に掴みたい人はこちらから。
- **[01-personal-aws-gitops-terraform.md](01-personal-aws-gitops-terraform.md)** ― OIDC・bootstrap・CI/CD・セキュア設計を **部品ごと** に深掘りした実践ログ。本記事で「詳細は01へ」とした各論はここに。

本記事が「時間軸」、01 が「部品ごと」、00 が「地図」。同じプロジェクトを 3 つの切り口で行き来すると立体的に掴める。

---

*この記事はリポジトリ `Kagayama0208/iac-aws` の実装をもとにした学習ログです。掲載のコードは抜粋で、アカウント ID・実バケット名などの機密はマスクしています。*
