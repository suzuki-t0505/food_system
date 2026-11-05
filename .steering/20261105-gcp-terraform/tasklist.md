# タスクリスト: GCP 本番基盤の Terraform 化

- 要求: [requirements.md](requirements.md) / 設計: [design.md](design.md)
- 凡例: `[ ]` 未着手 / `[x]` 完了

## 1. アプリ側(リリース)

- [x] 1.1 `food_vault` で `mix phx.gen.release --docker` を実行(`release.ex` は上書きしない)
  - 初回は bob.hex.pm への通信が拒否され `rel/` のみ生成。許可後に再実行して `Dockerfile`・`.dockerignore` を生成
- [x] 1.2 `food_ship` で `mix phx.gen.release --docker` を実行(同上)
- [x] 1.3 生成された `Dockerfile` のベースイメージを確認(Elixir 1.20.5 / OTP 29.1.2 / Debian trixie。修正不要)
- [x] 1.4 `FoodVault.Release` に `migrate/0`・`rollback/2`(生成物から取り込み)と `migrate_and_seed/0` を追加
- [x] 1.5 `FoodShip.Release` に同じものを追加
- [x] 1.6 両アプリで compile(`--warnings-as-errors`)・format・credo・test を通す(`make check`。在庫 447・発送 150 件パス)。`mix run --no-start` で `migrate_and_seed/0` を 2 回実行し冪等を確認
- [x] 1.7 本番イメージの `docker build` が通ることを確認(環境で可能な範囲)
  - 両アプリともビルド成功。Job と同じ `bin/<app> eval "<App>.Release.migrate_and_seed()"` で新規 DB にマイグレーション → シード(在庫: メーカー 2・倉庫 2・商品 3・管理者 1)、再実行で重複なし
  - サーバー起動: ログイン画面・アセット・在庫 API(Bearer)が 200、実行ユーザーは `nobody`。この検証環境は IPv6 が無く `::` で待ち受けできないため、確認時のみ IPv4 にした `runtime.exs` をマウントした(Cloud Run は第 2 世代の実行環境を指定)

## 2. Terraform(`infra/terraform/`)

- [x] 2.1 `versions.tf`・`backend.hcl.example`・`variables.tf`・`terraform.tfvars.example`
- [x] 2.2 `apis.tf`・`registry.tf`
- [x] 2.3 `network.tf`(VPC・サブネット・プライベートサービス接続)
- [x] 2.4 `sql.tf`(Cloud SQL インスタンス)
- [x] 2.5 `secrets.tf`(在庫 API トークン)
- [x] 2.6 `modules/app`(DB・ユーザー・秘密・SA・IAM・Cloud Run サービス・Job)
- [x] 2.7 `apps.tf`(在庫・発送のモジュール呼び出し。発送に在庫の URI とトークンを渡す)
- [x] 2.8 `armor.tf`(Cloud Armor ポリシー)
- [x] 2.9 `lb.tf`(IP・証明書・NEG・バックエンド・URL マップ・HTTPS/HTTP リダイレクト)
- [x] 2.10 `outputs.tf`
- [x] 2.11 ルートの `.gitignore` に Terraform の除外を追加
- [x] 2.12 `terraform fmt -check`・`terraform init -backend=false`・`terraform validate`・`terraform test`(3 件)を通す。ロックファイルに全プラットフォームの `zh:` ハッシュを記録
- [x] 2.13 `infra/terraform/README.md`(前提・初回構築・デプロイ・更新手順・state の扱い)

## 3. ドキュメント

- [x] 3.1 `architecture.md`(§2.1 本番構成、§11 Secret Manager、§16 #3 解決)
- [x] 3.2 `repository-structure.md`(`infra/terraform/`・`Dockerfile`・`rel/`)
- [x] 3.3 本タスクリストの完了反映・コミット・プッシュ
