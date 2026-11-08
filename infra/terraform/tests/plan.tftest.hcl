# 認証情報なしで構成を検証する(terraform test。プロバイダはモック)
mock_provider "google" {}
mock_provider "random" {}

variables {
  project_id           = "test-project"
  domain               = "example.com"
  food_vault_image_tag = "v1"
  food_ship_image_tag  = "v1"
  initial_admin_email  = "admin@example.com"
}

run "default" {
  command = plan

  assert {
    condition     = toset(google_compute_managed_ssl_certificate.this.managed[0].domains) == toset(["vault.example.com", "ship.example.com"])
    error_message = "証明書のドメインが vault / ship のホスト名になっていない"
  }

  assert {
    condition = alltrue([
      for r in google_compute_security_policy.this.rule : r.action == "allow" if r.priority == 2147483647
    ])
    error_message = "送信元を指定しないとき、既定ルールは allow"
  }

  assert {
    condition = anytrue([
      for r in google_compute_security_policy.this.rule : r.action == "deny(403)" if r.priority == 100
    ])
    error_message = "/api を遮断するルールが無い"
  }
}

run "deploy_identity" {
  command = plan

  assert {
    condition = (
      strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.repository == \"suzuki-t0505/food_system\"") &&
      strcontains(google_iam_workload_identity_pool_provider.github.attribute_condition, "assertion.ref == \"refs/heads/dev\"")
    )
    error_message = "WIF の attribute_condition がリポジトリと dev ブランチに限定されていない"
  }

  assert {
    condition     = google_artifact_registry_repository_iam_member.deployer_writer.role == "roles/artifactregistry.writer"
    error_message = "デプロイ用 SA に Artifact Registry の書き込み権限が無い"
  }

  assert {
    condition     = google_project_iam_member.deployer_run_developer.role == "roles/run.developer"
    error_message = "デプロイ用 SA に Cloud Run の更新権限(run.developer)が無い"
  }

  assert {
    condition = (
      toset(keys(google_service_account_iam_member.deployer_act_as)) == toset(["food_vault", "food_ship"]) &&
      alltrue([for m in google_service_account_iam_member.deployer_act_as : m.role == "roles/iam.serviceAccountUser"])
    )
    error_message = "actAs(serviceAccountUser)が vault / ship の実行 SA の 2 つだけに付いていない"
  }
}

run "deploy_branch_override" {
  command = plan

  variables {
    github_repository    = "example/other"
    github_deploy_branch = "staging"
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository == \"example/other\" && assertion.ref == \"refs/heads/staging\""
    error_message = "github_repository / github_deploy_branch が attribute_condition に反映されていない"
  }
}

run "invalid_github_repository" {
  command = plan

  variables {
    github_repository = "not-a-repo"
  }

  expect_failures = [var.github_repository]
}

run "restricted_source" {
  command = plan

  variables {
    allowed_source_ranges = ["203.0.113.0/24"]
  }

  assert {
    condition = alltrue([
      for r in google_compute_security_policy.this.rule : r.action == "deny(403)" if r.priority == 2147483647
    ])
    error_message = "送信元を指定したとき、既定ルールは deny"
  }
}

run "too_many_source_ranges" {
  command = plan

  variables {
    allowed_source_ranges = [for i in range(11) : "10.0.${i}.0/24"]
  }

  expect_failures = [var.allowed_source_ranges]
}
