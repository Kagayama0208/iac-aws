# はじめての Terraform + AWS ― ディレクトリ構造から読み解くプロジェクト案内

> 「リポジトリは開いたけど、ファイルが多くてどこから読めばいいか分からない」
> そんな初学者のために、このプロジェクトを **ディレクトリ構造** から一歩ずつ案内する地図記事。

## この記事のゴール

このリポジトリ（個人の AWS をコードで管理する `iac-aws`）には `.tf` ファイルやスクリプトがいくつも並んでいる。初めて見ると「結局このプロジェクトは何をしていて、どのファイルが何の役割なのか」が掴みづらい。

そこでこの記事では、

- このプロジェクトが **何を作っているのか**
- **どのディレクトリ・ファイルが何の役割を持つのか**
- コードを書いてから AWS にリソースができるまでの **全体の流れ**

を、上から順に追えるように整理する。

**対象読者**: プログラミングや Git は普段触っているが、**AWS や Terraform は初めて**という人。専門用語は出てくるたびに軽く補足し、記事末尾にミニ用語辞典も置く。

> この記事は「全体像をつかむ地図」。OIDC・CI/CD・セキュア設計といった一つひとつの深掘りは、続編の [01-personal-aws-gitops-terraform.md](01-personal-aws-gitops-terraform.md) で扱う。まずはここで土地勘をつけてほしい。

---

## 1. Terraform と IaC を30秒で

このプロジェクトの中心にあるのが **Terraform** というツールだ。ひとことで言うと:

> **作りたいインフラ（サーバーやストレージ）を「コード」で宣言し、コマンド一発で実体化するツール。**

こうした「インフラをコードで管理する」考え方を **IaC（Infrastructure as Code）** と呼ぶ。手作業で AWS の管理画面をポチポチ操作する代わりに、テキストファイルに「S3 バケットが1つ欲しい」と書いておけば、Terraform がその通りに AWS 上へ作ってくれる。

覚えておく操作は、まずはこの2つだけでいい:

| コマンド | 役割 |
|---|---|
| `terraform plan` | コードと現状を比べ、「何が作られ・変わり・消えるか」を**事前に表示**する（実行はしない） |
| `terraform apply` | plan の内容を **実際に AWS へ反映**する |

そしてもう一つだけ概念を: Terraform は「今 AWS に何を作ったか」の記録を **state（ステート）** というファイルに保存している。コードと現実をつなぐ台帳のようなものだ、と今は思っておけばよい。

---

## 2. このプロジェクトは何を作っているのか

このリポジトリは、**個人の AWS アカウントを手作業ではなくコードで管理する**ためのもの。実際に作っている「もの」は、大きく2つだけ:

- **`keiba-db` のバックアップ置き場** — 自宅で動かしているデータベースのバックアップを保存する、暗号化された S3 バケット。
- **`personal-blog` の画像置き場** — 個人ブログに載せる画像を保存する S3 バケット。

どちらも「S3 バケット（AWS のファイル置き場）を安全に1つ用意する」というシンプルな話だ。**そのシンプルな題材に対して、本番運用で大事になる作法（暗号化・最小権限・自動化）を一通り通してある**、というのがこのプロジェクトの性格になっている。

> **S3 とは**: AWS のオブジェクトストレージ。バケット（bucket）という入れ物にファイルを入れて使う、クラウド上のフォルダのようなもの。

---

## 3. ディレクトリ構造ツアー（本記事の主役）

まずはリポジトリ全体を俯瞰しよう。主要なファイルだけを抜き出すとこうなっている:

```
terraform-tf/
├── versions.tf            … Terraform / AWS Provider のバージョン指定
├── providers.tf           … AWS の接続設定（リージョン・共通タグ）
├── backend.tf             … state の保存先（S3 + DynamoDB）
├── variables.tf           … 変数の「定義」
├── terraform.tfvars       … 変数の「値」（実値・gitには載せない）
├── terraform.tfvars.example  … 値のテンプレート（こちらはgitに載せる）
├── keiba-db.tf            … keiba-db バックアップ用の S3 / KMS / IAM
├── personal-blog.tf       … ブログ画像用の S3 / IAM
├── outputs.tf             … 作った結果の「出力」（バケット名やキー）
│
├── bootstrap/             … 最初の一回だけ手で動かす土台づくり
│   ├── 01-tfstate-backend.sh   … state 用 S3 + DynamoDB を作る
│   ├── 02-github-oidc.sh       … GitHub 認証用の設定を作る
│   └── policies/               … IAM ポリシーの JSON
│
├── .github/workflows/
│   └── terraform.yml      … CI/CD（自動で plan / apply するパイプライン）
│
├── .tflint.hcl            … Terraform コードの静的チェック設定
│
└── articles/             … 解説記事（この記事もここ）
```

各エントリの役割を一覧にすると次の通り。**まだ全部を覚える必要はない**。「こういう係の人がいる」くらいの感覚で眺めてほしい。

| パス | 役割（ざっくり） |
|---|---|
| `versions.tf` | Terraform 本体と AWS Provider の使用バージョンを固定する |
| `providers.tf` | どの AWS リージョン（東京 `ap-northeast-1`）に、どんな共通タグで作るか |
| `backend.tf` | state ファイルを手元でなく S3 に置き、DynamoDB でロックする設定 |
| `variables.tf` | 「バケット名」などの変数の名前と型を **定義** する |
| `terraform.tfvars` | その変数に入れる **実際の値**。機密を含むので git には載せない |
| `terraform.tfvars.example` | 値の書き方を示すテンプレート（こちらは git に載せる） |
| `keiba-db.tf` | DB バックアップ用 S3・暗号鍵(KMS)・専用ユーザー(IAM)を定義 |
| `personal-blog.tf` | ブログ画像用 S3・専用ユーザー(IAM)を定義 |
| `outputs.tf` | 作成後に知りたい値（バケット名・アクセスキー等）を **出力** する |
| `bootstrap/` | Terraform を動かす **前** に手で用意する土台（後述） |
| `.github/workflows/terraform.yml` | push/PR をきっかけに自動で plan/apply を回す仕組み |
| `.tflint.hcl` | コードの書き方ミスを機械的にチェックするツールの設定 |
| `articles/` | このプロジェクトの解説記事置き場 |

> **気づき**: ファイル数は多いが、`.tf` の半分は「設定」、もう半分が「実際に作るリソース」。次の章でこの整理をする。

---

## 4. 3つの「役割グループ」で捉える

ファイルが10個以上あると圧倒されるが、役割で3グループに分けると一気に見通しがよくなる。

### (a) Terraform 本体の設定 ― 「どう動かすか」

`versions.tf` / `providers.tf` / `backend.tf` / `variables.tf`

ここはリソースそのものではなく、**Terraform をどう動かすかの前提**を決める層。「バージョンはこれ」「東京リージョンに作る」「state は S3 に置く」「変数はこういう型」――いわば舞台設定。最初は深く読まなくてよい。

### (b) 実際に作るリソース ― 「何を作るか」

`keiba-db.tf` / `personal-blog.tf`（＋ 結果を出す `outputs.tf`）

このプロジェクトの **主役**。実際に AWS 上へ S3 バケットや IAM ユーザーを生み出すのはこの2ファイルだ。「このプロジェクトは何を作っているの?」の答えは、ほぼここに書いてある。

### (c) 周辺の足回り ― 「どう運用するか」

`bootstrap/` / `.github/workflows/terraform.yml` / `.tflint.hcl`

リソースそのものではないが、**安全に・自動で回すための仕組み**。

- `bootstrap/` … state 置き場や GitHub からの認証設定など、**Terraform を動かすために最初の一回だけ手で用意する**土台。「鶏が先か卵が先か」問題を避けるために、あえて Terraform の外に置いてある（詳しくは [01](01-personal-aws-gitops-terraform.md) で）。
- `.github/workflows/terraform.yml` … GitHub に push したら自動でチェック→plan→apply を回す **CI/CD**。
- `.tflint.hcl` … コードの書き方の間違いを機械的に見つける lint ツールの設定。

つまり **(a) で土台を決め、(b) で中身を作り、(c) で安全に運用する**、という3層構造だと捉えると迷子になりにくい。

---

## 5. 1ファイルだけ中を覗いてみる

雰囲気を掴むため、グループ(b)の [personal-blog.tf](../personal-blog.tf) を少しだけ覗いてみよう。難しい部分（IAM や暗号鍵）は飛ばして、**S3 バケット1つ**に注目する。

```hcl
resource "aws_s3_bucket" "blog-images" {
  bucket           = var.blog_images_bucket_name
  bucket_namespace = "account-regional"

  tags = {
    Project = "personal-blog"
    Purpose = "blog images"
  }
}
```

読み方はこう:

- `resource "aws_s3_bucket" "blog-images"` … 「**S3 バケット**を1つ作る。コード上の呼び名は `blog-images`」という宣言。`resource "<種類>" "<呼び名>"` がリソース定義の基本形。
- `bucket = var.blog_images_bucket_name` … 実際のバケット名は、変数（`variables.tf` で定義、`terraform.tfvars` で値を設定）から受け取る。
- `tags = {...}` … 「何のためのバケットか」を示すラベル。後で AWS 上で見分けるのに役立つ。

同じファイルには、このバケットを安全にするための設定が続く:

```hcl
# 公開を物理的にブロックする
resource "aws_s3_bucket_public_access_block" "blog-images" {
  bucket                  = aws_s3_bucket.blog-images.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 過去バージョンを残す（誤削除・上書きに備える）
resource "aws_s3_bucket_versioning" "blog-images" {
  bucket = aws_s3_bucket.blog-images.id
  versioning_configuration {
    status = "Enabled"
  }
}
```

- **public access block** … 4項目すべて `true`。これでバケットが誤ってインターネット公開される事故を**仕組みとして防ぐ**。
- **versioning** … ファイルの上書き・削除があっても過去の版を残す。バックアップや誤操作からの復旧に効く。

ポイントは、**「バケットを作る」だけで終わらず、安全側の設定をコードで明示している**こと。手作業だと忘れがちなこうした設定も、コードに書いておけば毎回・確実に適用される。これが IaC のうれしさだ。

> IAM ユーザーや暗号鍵(KMS)の話はあえて省いた。最小権限の設計などは [01](01-personal-aws-gitops-terraform.md) で詳しく扱う。

---

## 6. 全体の流れ（コード → AWS）

最後に、コードを書いてから AWS にリソースができるまでの流れを俯瞰しておく。

```
  あなた
    │ 1. .tf を編集して git push / Pull Request
    ▼
  GitHub
    │ 2. GitHub Actions が起動（.github/workflows/terraform.yml）
    ▼
  CI/CD パイプライン
    │ 3. コードをチェック（fmt / tflint / セキュリティスキャン）
    │ 4. (OIDC で AWS に安全にログイン ※鍵を持たない)
    │ 5. terraform plan で差分を表示 → PR にコメント
    │ 6. main にマージされたら terraform apply
    ▼
  AWS
       S3 バケットや IAM ユーザーが実際に作られる
```

注目してほしいのは、**人が AWS 管理画面を手で触る場面が（最初の bootstrap を除けば）ない**こと。変更はすべてコード → Pull Request → 自動適用、という流れに乗る。「いつ・誰が・なぜ変えたか」が Git の履歴に全部残るのが、この作り方の最大の利点だ。

各ステップ（OIDC で鍵なしログインする仕組み、CI/CD の中身、bootstrap の鶏卵問題）は、続編 [01](01-personal-aws-gitops-terraform.md) で一つずつ掘り下げる。

---

## 7. つまずきやすい用語ミニ辞典

| 用語 | ざっくりした意味 |
|---|---|
| **IaC** | インフラをコードで宣言・管理する考え方。Infrastructure as Code |
| **Terraform** | IaC を実現する代表的ツール。`.tf` ファイルを読んで AWS 等にリソースを作る |
| **provider** | Terraform が「どのクラウドを操作するか」のプラグイン。ここでは AWS |
| **plan / apply** | plan＝差分の事前表示、apply＝実際に反映 |
| **state** | Terraform が「今何を作ったか」を記録する台帳ファイル |
| **backend** | その state をどこに置くか。ここでは S3 + DynamoDB（チームや CI で共有するため） |
| **S3** | AWS のファイル置き場。バケットという入れ物を使う |
| **IAM** | AWS の権限管理。ユーザーや「できること」を定義する |
| **KMS** | AWS の暗号鍵の管理サービス |
| **OIDC** | 長期の鍵を置かずに GitHub から AWS へ安全にログインする仕組み |
| **CI/CD** | push/PR をきっかけにチェックやデプロイを自動実行する仕組み |
| **bootstrap** | Terraform を動かす前に、手で一度だけ用意しておく土台 |

---

## 8. 次に読む

ここまでで、**プロジェクトの地図**（何を作っていて、どのファイルが何の役割で、全体がどう流れるか）は掴めたはず。次は中身の深掘りへ:

- **[01-personal-aws-gitops-terraform.md](01-personal-aws-gitops-terraform.md)** — OIDC でのキーレス認証、bootstrap の鶏卵問題、CI/CD パイプライン設計、S3 + KMS + IAM の最小権限といった「一つひとつの作り込み」を実践ログとして解説。

まずは本記事の地図を片手に、実際の `.tf` ファイルを開いて「どのグループの・何のファイルか」を確かめてみるのがおすすめだ。

---

*この記事はリポジトリ `Kagayama0208/iac-aws` の実装をもとにした入門ガイドです。掲載のコードは抜粋で、アカウント ID・実バケット名などの機密はマスクしています。*
