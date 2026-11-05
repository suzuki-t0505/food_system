# 在庫 API のサービストークン(在庫: INVENTORY_API_TOKENS、発送: INVENTORY_API_TOKEN に同じ値を渡す)
resource "random_password" "inventory_api_token" {
  length  = 64
  special = false
}

resource "google_secret_manager_secret" "inventory_api_token" {
  secret_id = "inventory-api-token"

  replication {
    auto {}
  }

  depends_on = [google_project_service.this]
}

resource "google_secret_manager_secret_version" "inventory_api_token" {
  secret      = google_secret_manager_secret.inventory_api_token.id
  secret_data = random_password.inventory_api_token.result
}
