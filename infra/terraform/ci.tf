# GitHub Actions(deploy-dev.yml)からのデプロイ用: Workload Identity Federation とデプロイ用サービスアカウント。
# サービスアカウントキーは作らない。認証できるのは var.github_repository の var.github_deploy_branch 上のワークフローだけ。

# --- Workload Identity Federation ---

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # 条件を満たさない OIDC トークン(他リポジトリ・dev 以外のブランチなど)はトークン交換の時点で拒否される
  attribute_condition = "assertion.repository == \"${var.github_repository}\" && assertion.ref == \"refs/heads/${var.github_deploy_branch}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# --- デプロイ用サービスアカウント ---

resource "google_service_account" "deployer" {
  account_id   = "food-system-deployer"
  display_name = "GitHub Actions デプロイ用"

  depends_on = [google_project_service.this]
}

resource "google_service_account_iam_member" "deployer_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# イメージの push(このリポジトリのみ)
resource "google_artifact_registry_repository_iam_member" "deployer_writer" {
  project    = google_artifact_registry_repository.this.project
  location   = google_artifact_registry_repository.this.location
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.deployer.member
}

# サービス・Job の更新と Job の実行
resource "google_project_iam_member" "deployer_run_developer" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = google_service_account.deployer.member
}

# Cloud Run の更新時に実行用サービスアカウントを actAs する(両アプリの実行 SA のみ)
resource "google_service_account_iam_member" "deployer_act_as" {
  for_each = {
    food_vault = module.food_vault.service_account_name
    food_ship  = module.food_ship.service_account_name
  }

  service_account_id = each.value
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.deployer.member
}
