# 要求内容: GCP 本番基盤の Terraform 化

- 根拠: [architecture.md §2.1・§11・§16 #3](../../docs/architecture.md)(本番構成が未定)
- 対象: `food_vault`(在庫)・`food_ship`(発送)の 2 アプリを GCP 上で動かす基盤
- 位置づけ: §16 #3「本番の構成」を解決する。業務ロジックは変えない

## 背景

リポジトリには `Dockerfile.dev` しかなく、本番イメージ・リリース手順・デプロイ先が無い。`{App}.Release` は `create_initial_admin/0` のみで、マイグレーションのリリースタスクも無い。本番では TLS 終端と、在庫の `/api` を発送システムからの呼び出しに限定することが求められている(§2.1・§7)。

## 構成(ユーザー指定)

| 要素 | 用途 |
| :-- | :-- |
| ロードバランサ | 外部 HTTPS ロードバランサ(グローバル外部アプリケーション LB)。TLS 終端・HTTP→HTTPS リダイレクト |
| Cloud Armor | LB のバックエンドに付けるセキュリティポリシー |
| Cloud Run(サービス) | `food_vault` / `food_ship` を **アプリごとに 1 サービス** |
| Cloud Run Job | マイグレーション兼シードデータ投入。**アプリごとに 1 ジョブ** |
| Cloud SQL | PostgreSQL 15。**1 インスタンスに 2 DB**(`food_vault` / `food_ship`)、ユーザーもアプリごとに分ける |

## 要求(スコープ)

### Terraform

- `infra/terraform/` 配下に作成する。環境ごとの変数(プロジェクト ID・リージョン・ドメインなど)は `terraform.tfvars` で与え、実値はコミットしない(`terraform.tfvars.example` を置く)
- state は GCS バケット(バックエンド設定は利用者が指定)
- 作成するリソース
  - 必要な API の有効化、Artifact Registry(Docker リポジトリ)
  - VPC・サブネット(Private Google Access 有効)、Cloud SQL 用のプライベートサービス接続
  - Cloud SQL(プライベート IP のみ・パブリック IP なし、自動バックアップ・PITR、削除保護)、DB・ユーザー
  - Secret Manager(`DATABASE_URL`・`SECRET_KEY_BASE`・`INITIAL_ADMIN_PASSWORD`・在庫 API トークン)。値は Terraform の `random_password` で生成する
  - Cloud Run サービス × 2、Cloud Run Job × 2、それぞれ専用のサービスアカウント(最小権限)
  - 外部 HTTPS LB(サーバーレス NEG、Google マネージド証明書、ホスト名で振り分け: 例 `vault.<domain>` / `ship.<domain>`)、静的グローバル IP
  - Cloud Armor ポリシー
- コンテナイメージのビルド・プッシュは Terraform の外(手順を README に書く)。イメージ名は変数で渡す

### ネットワークとアクセス制御

- Cloud Run の ingress は `internal-and-cloud-load-balancing`(`*.run.app` への直アクセスを外部から不可)
- Cloud Run・Job は Direct VPC egress で VPC に入り、Cloud SQL にプライベート IP で接続する
- **在庫の `/api` は外部(LB 経由)から遮断**する(Cloud Armor で `/api/` を deny)。発送 → 在庫は VPC 経由で在庫サービスの内部 URL(`*.run.app`)を呼ぶ(`INVENTORY_API_BASE_URL`)
- Cloud Armor: OWASP 事前構成ルール(SQLi・XSS など)、レート制限(IP 単位)。許可 IP の制限は変数で任意指定(未指定なら全許可)

### Cloud Run Job(マイグレーション兼シード)

- 1 回の実行で ①マイグレーション → ②シード(`priv/repo/seeds.exs`。初期管理者と開発用マスタ。どちらも冪等)を行う
- 今回の GCP 環境は**開発環境用**のため、開発用マスタ(在庫: メーカー 2・倉庫 2・商品 3)も投入する
- デプロイ手順は「イメージ更新 → ジョブ実行 → サービス更新」の順(README に記す)

### アプリ側の追加(Terraform を動かすのに必要な最小限)

- 両アプリに本番用 `Dockerfile` と `Release` を **`mix phx.gen.release --docker` で生成**する(root 以外のユーザーで実行)
- 生成物に合わせて `{App}.Release` を修正し、既存の `create_initial_admin/0`・`run/0` を残したまま `migrate/0`(生成)と Job から呼ぶ `migrate_and_seed/0` を持たせる
- `INVENTORY_API_BASE_URL` / `INVENTORY_API_TOKEN` は環境変数として Cloud Run に渡すだけ(`food_ship` 側の読み込み実装は段階 4)

### 周辺

- `architecture.md`(§2.1・§11・§16 #3)・`repository-structure.md` に反映する

## スコープ外

- CI/CD(GitHub Actions からのデプロイ)、監視・アラート、Chromium(ChromicPDF)の本番構成
- 独自ドメインの DNS レコード登録(LB の IP を出力し、利用者が設定する)
- `X-Forwarded-For` からの送信元 IP の扱い(§12)
- 発送システムの業務機能・在庫 API クライアントの実装(段階 4)

## 確認結果

| # | 内容 | 決定 |
| :-- | :-- | :-- |
| 1 | 対象アプリ | 在庫・発送の両方を GCP に載せる |
| 2 | シード | 開発環境用のため、初期管理者に加えて開発用マスタも投入する |
| 3 | 本番 Dockerfile・Release | `mix phx.gen.release --docker` で生成し、必要に応じて `release.ex` を修正する |
| 4 | リージョン・ドメイン | `asia-northeast1`。独自ドメインあり(変数 `domain` で指定) |
