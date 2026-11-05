output "service_name" {
  value = google_cloud_run_v2_service.this.name
}

output "service_uri" {
  description = "Cloud Run の内部 URL(*.run.app。ingress により外部からは到達不可)"
  value       = google_cloud_run_v2_service.this.uri
}

output "job_name" {
  value = google_cloud_run_v2_job.migrate.name
}

output "initial_admin_password_secret" {
  value = google_secret_manager_secret.this["INITIAL_ADMIN_PASSWORD"].secret_id
}
