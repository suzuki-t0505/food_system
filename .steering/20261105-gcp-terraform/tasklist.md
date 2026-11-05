# タスクリスト: GCP 本番基盤の Terraform 化

- 要求: [requirements.md](requirements.md) / 設計: [design.md](design.md)
- 凡例: `[ ]` 未着手 / `[x]` 完了

## 1. アプリ側(リリース)

- [ ] 1.1 `food_vault` で `mix phx.gen.release --docker` を実行(`release.ex` は上書きしない)
- [ ] 1.2 `food_ship` で `mix phx.gen.release --docker` を実行(同上)
- [ ] 1.3 生成された `Dockerfile` のベースイメージ(Elixir 1.20.5 / OTP 29)を確認・修正
- [ ] 1.4 `FoodVault.Release` に `migrate/0`・`rollback/2`(生成物から取り込み)と `migrate_and_seed/0` を追加
- [ ] 1.5 `FoodShip.Release` に同じものを追加
- [ ] 1.6 両アプリで compile(`--warnings-as-errors`)・format・credo・test を通す
- [ ] 1.7 本番イメージの `docker build` が通ることを確認(環境で可能な範囲)

## 2. Terraform(`infra/terraform/`)

- [ ] 2.1 `versions.tf`・`backend.hcl.example`・`variables.tf`・`terraform.tfvars.example`
- [ ] 2.2 `apis.tf`・`registry.tf`
- [ ] 2.3 `network.tf`(VPC・サブネット・プライベートサービス接続)
- [ ] 2.4 `sql.tf`(Cloud SQL インスタンス)
- [ ] 2.5 `secrets.tf`(在庫 API トークン)
- [ ] 2.6 `modules/app`(DB・ユーザー・秘密・SA・IAM・Cloud Run サービス・Job)
- [ ] 2.7 `apps.tf`(在庫・発送のモジュール呼び出し。発送に在庫の URI とトークンを渡す)
- [ ] 2.8 `armor.tf`(Cloud Armor ポリシー)
- [ ] 2.9 `lb.tf`(IP・証明書・NEG・バックエンド・URL マップ・HTTPS/HTTP リダイレクト)
- [ ] 2.10 `outputs.tf`
- [ ] 2.11 ルートの `.gitignore` に Terraform の除外を追加
- [ ] 2.12 `terraform fmt -check`・`terraform init -backend=false`・`terraform validate` を通す
- [ ] 2.13 `infra/terraform/README.md`(前提・初回構築・デプロイ・更新手順・state の扱い)

## 3. ドキュメント

- [ ] 3.1 `architecture.md`(§2.1 本番構成、§11 Secret Manager、§16 #3 解決)
- [ ] 3.2 `repository-structure.md`(`infra/terraform/`・`Dockerfile`・`rel/`)
- [ ] 3.3 本タスクリストの完了反映・コミット・プッシュ
