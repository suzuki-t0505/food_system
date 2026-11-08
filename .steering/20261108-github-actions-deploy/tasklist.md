# タスクリスト: GitHub Actions による dev 環境への自動デプロイ

- 要求: [requirements.md](requirements.md) / 設計: [design.md](design.md)
- 凡例: `[ ]` 未着手 / `[x]` 完了

## 1. Terraform(`infra/terraform/`)

- [x] 1.1 `apis.tf`: `iamcredentials.googleapis.com`・`sts.googleapis.com` を追加
- [x] 1.2 `variables.tf`: `github_repository`(空でないことを validation)・`github_deploy_branch` を追加。`food_*_image_tag` の description に「初回作成用」と追記
- [x] 1.3 `modules/app/outputs.tf`: `service_account_name`(実行 SA のリソース名)を追加
- [x] 1.4 `modules/app/main.tf`: Cloud Run サービス・Job に `lifecycle { ignore_changes }`(`image`・`client`・`client_version`)を追加
- [x] 1.5 `ci.tf`(新規): WIF プール/プロバイダ(`attribute_condition` でリポジトリと ref を限定)
- [x] 1.6 `ci.tf`: デプロイ用 SA、`workloadIdentityUser`、`artifactregistry.writer`(リポジトリ単位)、`run.developer`、`serviceAccountUser`(vault / ship の実行 SA のみ)
- [x] 1.7 `outputs.tf`: `workload_identity_provider`・`deployer_service_account` を追加
- [x] 1.8 `tests/plan.tftest.hcl`: `attribute_condition`・ロール付与・`github_repository` 空の validation を追加
- [x] 1.9 `terraform fmt -check -recursive` / `init -backend=false` / `validate` / `test` を通す
  - Terraform 1.9.8 で fmt・validate が通り、test は 6 件パス

## 2. ワークフロー

- [x] 2.1 `.github/workflows/deploy-dev.yml`: トリガー(`dev` への push・`workflow_dispatch`)・permissions・concurrency
- [x] 2.2 `build-push` ジョブ(matrix `food_vault` / `food_ship`): WIF 認証 → `configure-docker` → buildx でビルド・push(タグは SHA、GHA キャッシュ)
- [x] 2.3 `deploy` ジョブ: vault → ship の順に「Job 更新 → Job 実行(`--wait`) → サービス更新」、ジョブサマリ出力
- [x] 2.4 `actionlint`(利用可能なら)または YAML 構文チェックを通す
  - actionlint は取得したバイナリの実行が許可されず未実施。YAML は構文チェック(PyYAML)のみ通した。実機での確認は Actions の初回実行で行う
- [ ] 2.5 `docker build ./food_vault`・`./food_ship` を確認(Dockerfile は変更なし。環境で不可なら報告)
  - この環境では docker build 内の `mix local.hex` が hex.pm に届かず失敗(ネットワーク制限)。Dockerfile は未変更で、PR 後の Actions 上で確認する

## 3. ドキュメント

- [x] 3.1 `infra/terraform/README.md`: 「更新(デプロイ)」を自動デプロイに書き換え、WIF の初回セットアップ(Variables 登録・`dev` ブランチ作成)、`apply` してもイメージが戻らないこと、プールのソフト削除の注記を追記
- [x] 3.2 `docs/architecture.md`: §2.3(デプロイの流れ)・§14(`deploy-dev` を追記)・§16 #3(CI/CD を解決済みに)
- [x] 3.3 `docs/development-guidelines.md` §3.1: `dev` ブランチと「`dev` へのマージ = dev 環境へ自動デプロイ」の運用
- [x] 3.4 `docs/repository-structure.md`: `deploy-dev.yml`・`ci.tf` を追記

## 4. 作業者(ユーザー)側の手順(実装完了後)

- [ ] 4.1 `terraform plan` で Cloud Run のイメージ差分が出ないことを確認し、`terraform apply`
- [ ] 4.2 `terraform output` の値を GitHub の Environment `dev` の Variables(`GCP_PROJECT_ID`・`GCP_REGION`・`GCP_WORKLOAD_IDENTITY_PROVIDER`・`GCP_SERVICE_ACCOUNT`)に登録
- [ ] 4.3 `main` から `dev` ブランチを作成(必要ならブランチ保護を設定)
- [ ] 4.4 `dev` への PR をマージし、Actions の成功・サービスのイメージが当該 SHA・Job の実行成功を確認
- [ ] 4.5 `terraform plan` でイメージの差分が出ないことを再確認
