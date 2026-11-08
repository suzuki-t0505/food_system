output "lb_ip_address" {
  description = "DNS の A レコードに登録する IP"
  value       = google_compute_global_address.lb.address
}

output "urls" {
  value = {
    food_vault = "https://${local.vault_host}"
    food_ship  = "https://${local.ship_host}"
  }
}

output "image_repository" {
  description = "イメージのプッシュ先"
  value       = local.registry
}

output "migrate_jobs" {
  description = "gcloud run jobs execute <name> --region <region> --wait で実行する"
  value = {
    food_vault = module.food_vault.job_name
    food_ship  = module.food_ship.job_name
  }
}

output "workload_identity_provider" {
  description = "GitHub Environment の Variables GCP_WORKLOAD_IDENTITY_PROVIDER に登録する"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deployer_service_account" {
  description = "GitHub Environment の Variables GCP_SERVICE_ACCOUNT に登録する"
  value       = google_service_account.deployer.email
}

output "initial_admin_password_secrets" {
  description = "gcloud secrets versions access latest --secret <name> で初期管理者のパスワードを確認する"
  value = {
    food_vault = module.food_vault.initial_admin_password_secret
    food_ship  = module.food_ship.initial_admin_password_secret
  }
}

output "food_vault_internal_uri" {
  description = "在庫サービスの内部 URL(発送の INVENTORY_API_BASE_URL)"
  value       = module.food_vault.service_uri
}
