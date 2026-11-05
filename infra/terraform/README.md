# GCP 基盤(Terraform)

在庫管理システム(`food_vault`)と発送システム(`food_ship`)を GCP で動かす構成。設計は [.steering/20261105-gcp-terraform/design.md](../../.steering/20261105-gcp-terraform/design.md)。

```
利用者 ─HTTPS→ 外部アプリケーション LB(Cloud Armor)─→ Cloud Run: food-vault / food-ship ─VPC→ Cloud SQL(PostgreSQL 15)
                                                       food-ship ─VPC(内部)→ food-vault /api/v1
Cloud Run Job: food-vault-migrate / food-ship-migrate(マイグレーション → シード)
```

| 公開 URL | 中身 |
| :-- | :-- |
| `https://vault.<domain>` | 在庫管理システム(`/api/*` は Cloud Armor で 403。発送からは VPC 経由で呼ぶ) |
| `https://ship.<domain>` | 発送システム |

## 前提

- Terraform 1.9 以上、`gcloud` CLI
- 課金が有効な GCP プロジェクトと、作業者に Owner 相当の権限
- 独自ドメインの DNS を編集できること

## 初回構築

```bash
cd infra/terraform
PROJECT_ID=your-project-id
REGION=asia-northeast1

# 1. state 用バケット(アクセスは作業者に限定する。生成したパスワード・トークンが state に入る)
gcloud storage buckets create gs://${PROJECT_ID}-tfstate --project ${PROJECT_ID} --location ${REGION} \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://${PROJECT_ID}-tfstate --versioning

# 2. 変数とバックエンドの設定
cp backend.hcl.example backend.hcl            # bucket を書き換える
cp terraform.tfvars.example terraform.tfvars  # project_id / domain / initial_admin_email / イメージのタグ
terraform init -backend-config=backend.hcl

# 3. API と Artifact Registry だけ先に作る(イメージのプッシュ先が必要なため)
terraform apply -target=google_project_service.this -target=google_artifact_registry_repository.this

# 4. イメージをビルドしてプッシュ(タグは terraform.tfvars と合わせる)
REPO=$(terraform output -raw image_repository 2>/dev/null || echo ${REGION}-docker.pkg.dev/${PROJECT_ID}/food-system)
gcloud builds submit ../../food_vault --project ${PROJECT_ID} --region ${REGION} --tag ${REPO}/food_vault:v0.1.0
gcloud builds submit ../../food_ship  --project ${PROJECT_ID} --region ${REGION} --tag ${REPO}/food_ship:v0.1.0

# 5. 残りを作る
terraform apply

# 6. マイグレーション → シード(初期管理者・開発用マスタ。冪等)
gcloud run jobs execute food-vault-migrate --project ${PROJECT_ID} --region ${REGION} --wait
gcloud run jobs execute food-ship-migrate  --project ${PROJECT_ID} --region ${REGION} --wait

# 7. DNS に A レコードを 2 つ登録する(vault.<domain> / ship.<domain> → この IP)
terraform output lb_ip_address
# 証明書が ACTIVE になるまで待つ(数十分〜)
gcloud compute ssl-certificates describe food-system --global --format='value(managed.status,managed.domainStatus)'
```

初期管理者のパスワード(初回ログイン時に変更を求められる):

```bash
gcloud secrets versions access latest --secret food-vault-initial-admin-password
gcloud secrets versions access latest --secret food-ship-initial-admin-password
```

## 更新(デプロイ)

1. 新しいタグでイメージをビルド・プッシュ(初回構築の 4)
2. `terraform.tfvars` の `food_vault_image_tag` / `food_ship_image_tag` を変更し `terraform apply`
3. Job を実行(初回構築の 6)

`apply` でサービスと Job が同時に新しいイメージになり、Job の実行までは新コードが旧スキーマで動く。マイグレーションは旧コードと新コードの両方で動く形にする(architecture §5 の「NOT NULL 追加は `default:` 付き」など)。

## 設定のポイント

| 項目 | 内容 |
| :-- | :-- |
| Cloud Run の ingress | `internal-and-cloud-load-balancing`。`*.run.app` へ外部から直接は届かない |
| 在庫 API | Cloud Armor で `/api` を外部から遮断。発送は egress を全トラフィック VPC 経由にし、在庫の `*.run.app` を内部トラフィックとして呼ぶ(`INVENTORY_API_BASE_URL`)。認証は Bearer トークン(Secret Manager `inventory-api-token`) |
| 発送の対象倉庫 | `inventory_warehouse_id` は初回は空のままでよい(発送は空でも起動するが、設定するまで伝票登録・再引当・数量変更を拒否し、画面に警告を出す)。在庫を構築・初期管理者でマスタ(倉庫)を作ったあと、在庫 API(`GET /api/v1/warehouses`、Bearer トークン)で倉庫の ID を確認し、`terraform.tfvars` に設定して `apply` する |
| 発送のインターネット接続 | egress が全トラフィック VPC のため、外部へは出られない。必要になったら Cloud NAT を追加する |
| Cloud SQL | プライベート IP のみ。1 インスタンスに DB `food_vault` / `food_ship`(ユーザーも別) |
| 秘密情報 | `DATABASE_URL`・`SECRET_KEY_BASE`・初期管理者パスワード・在庫 API トークンを Terraform が生成し Secret Manager に置く |
| Cloud Armor | `/api` 遮断 → OWASP 事前構成ルール(感度 1)→ IP ごとのレート制限(`rate_limit_per_minute`)→ 既定。`allowed_source_ranges` を指定するとそれ以外を 403 |

- Cloud Armor の誤検知(フォームの入力内容など)が出たら、`armor.tf` の該当ルールに `opt_out_rule_ids` を足して外す。ログは LB のバックエンドのログ(`enforcedSecurityPolicy`)で確認する
- 秘密の値を作り直すときは `terraform apply -replace=module.food_vault.random_password.secret_key_base` のように `-replace` を使う(サービスは `latest` を参照するので、apply 後に新しいリビジョンが必要なら再デプロイする)

## 検証(認証情報なし)

```bash
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test   # プロバイダをモックして plan を評価する(tests/)
```

## 削除

`deletion_protection = false` にして `apply` してから `terraform destroy`。Cloud SQL のバックアップも消えるので注意。
