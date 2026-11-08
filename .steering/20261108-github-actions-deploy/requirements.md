# 要求内容: GitHub Actions による dev 環境への自動デプロイ

- 根拠: [architecture.md §2.3・§14・§16 #3](../../docs/architecture.md)(CI/CD が未決)、[20261105-gcp-terraform/requirements.md](../20261105-gcp-terraform/requirements.md)(スコープ外としていた CI/CD)
- 対象: `food_vault`(在庫)・`food_ship`(発送)の 2 アプリの GCP(Cloud Run / Cloud Run Job)へのデプロイ
- 位置づけ: §16 #3「CI/CD」を解決する。アプリの業務ロジックは変えない

## 背景

現状の GitHub Actions は PR で動く CI(`.github/workflows/ci.yml`)のみで、デプロイは手動(`gcloud builds submit` → `terraform.tfvars` のタグ変更 → `terraform apply` → `gcloud run jobs execute`)。dev 環境へ反映するたびに作業者の手が必要で、手順の抜け漏れも起きやすい。

## 要求(スコープ)

### ブランチ戦略

- `feature/*`・`fix/*`・`docs/*` から `dev` へ PR を出し、既存 CI(`ci.yml`)を品質ゲートとする
- **`dev` にマージ(= `dev` への push)されたら自動デプロイ**する。`main` ではデプロイしない(本番化は別作業)
- `main` は従来どおり直接コミット禁止。`dev` ブランチは `main` から作成する(GitHub 上の操作)

### デプロイ(`.github/workflows/deploy-dev.yml`)

- トリガー: `dev` への push と手動実行(`workflow_dispatch`)
- アプリ(`food_vault`・`food_ship`)ごとに Docker イメージをビルドし、Artifact Registry(`food-system` リポジトリ)へ push する
  - ビルドコンテキストはアプリのディレクトリ(Dockerfile が各アプリ配下のため)
  - タグはコミット SHA(不変タグ。`latest` は使わない)
- 次の順で Cloud Run を更新する(アプリは vault → ship の順)
  1. Cloud Run Job(`food-<app>-migrate`)のイメージを更新
  2. Job を実行して完了を待つ(マイグレーション → シード。失敗したらそこで停止し、サービスは旧イメージのまま)
  3. Cloud Run サービス(`food-<app>`)のイメージを更新
- 同時に複数のデプロイが走らないよう直列化する(実行中のデプロイは中断しない)

### GCP 認証

- **Workload Identity Federation**(キーレス)で認証する。サービスアカウントキーは発行・保存しない
- 認証できるのは、このリポジトリの `dev` ブランチからのワークフローに限定する
- デプロイ用サービスアカウントは最小権限(Artifact Registry への書き込み、Cloud Run の更新・Job 実行、2 つの実行用サービスアカウントの `actAs` のみ)

### Terraform との整合

- WIF プール/プロバイダ、デプロイ用サービスアカウントとその IAM を Terraform(`infra/terraform/`)に追加する
- Cloud Run サービス・Job の `image` は CI が更新するため、Terraform では `ignore_changes` にする。以後の `terraform apply` でイメージが巻き戻らないこと
- `image` 変数・`food_*_image_tag` は初回構築用として残す(README の初回手順は変えない)

### 周辺

- GitHub 側の設定値(Environment `dev` の Variables: `GCP_PROJECT_ID`・`GCP_REGION`・`GCP_WORKLOAD_IDENTITY_PROVIDER`・`GCP_SERVICE_ACCOUNT`)は Terraform の output から取得できるようにし、登録手順を README に書く
- `infra/terraform/README.md`・`architecture.md`・`development-guidelines.md`(§3.1 のブランチ運用)に反映する

## スコープ外

- `main` ブランチ(本番)へのデプロイ、環境ごとの GCP プロジェクト分離、承認フロー
- 初回の WIF 作成(Terraform の `apply` は作業者が手動で行う。ワークフローからは作れない)
- ロールバック専用のワークフロー(過去 SHA は `gcloud run services update --image` で戻せる。`workflow_dispatch` は現在のブランチをビルドする)
- 監視・アラート、Chromium(ChromicPDF)の本番構成
- 互換性のないマイグレーションの自動回避(Job 実行後〜サービス切替までは旧コードが新スキーマで動くため、これまでどおり architecture §5 の「NOT NULL 追加は `default:` 付き」に従う)

## 確認結果

| # | 内容 | 決定 |
| :-- | :-- | :-- |
| 1 | GCP 認証 | Workload Identity Federation(キーレス) |
| 2 | 環境構成 | `dev` ブランチ → 1 つの GCP 環境。将来 `main` / 本番を足せる作りにする |
| 3 | Terraform との整合 | CI が `gcloud` で直接イメージを更新し、Terraform は `image` を `ignore_changes` にする |
| 4 | マイグレーション | イメージ更新後に Job を実行して完了を待つ。順序は「Job 更新 → Job 実行 → サービス更新」 |
