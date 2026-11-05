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
