resource "google_artifact_registry_repository" "this" {
  location      = var.region
  repository_id = "food-system"
  format        = "DOCKER"
  description   = "food_vault / food_ship のコンテナイメージ"

  depends_on = [google_project_service.this]
}

locals {
  registry = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.this.repository_id}"
}
