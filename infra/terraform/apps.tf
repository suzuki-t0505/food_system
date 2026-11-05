locals {
  vault_host = "${var.vault_subdomain}.${var.domain}"
  ship_host  = "${var.ship_subdomain}.${var.domain}"
}

module "food_vault" {
  source = "./modules/app"

  name           = "food-vault"
  otp_app        = "food_vault"
  release_module = "FoodVault"
  image          = "${local.registry}/food_vault:${var.food_vault_image_tag}"
  project_id     = var.project_id
  region         = var.region
  host           = local.vault_host

  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.run.id
  egress     = "PRIVATE_RANGES_ONLY"

  sql_instance_name = google_sql_database_instance.this.name
  sql_private_ip    = google_sql_database_instance.this.private_ip_address

  min_instances       = var.min_instances
  max_instances       = var.max_instances
  initial_admin_email = var.initial_admin_email

  secret_env = {
    INVENTORY_API_TOKENS = google_secret_manager_secret.inventory_api_token.secret_id
  }

  depends_on = [google_secret_manager_secret_version.inventory_api_token]
}

module "food_ship" {
  source = "./modules/app"

  name           = "food-ship"
  otp_app        = "food_ship"
  release_module = "FoodShip"
  image          = "${local.registry}/food_ship:${var.food_ship_image_tag}"
  project_id     = var.project_id
  region         = var.region
  host           = local.ship_host

  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.run.id
  # 在庫の *.run.app への呼び出しを VPC 経由(内部トラフィック)にするため全トラフィックを VPC に流す
  egress = "ALL_TRAFFIC"

  sql_instance_name = google_sql_database_instance.this.name
  sql_private_ip    = google_sql_database_instance.this.private_ip_address

  min_instances       = var.min_instances
  max_instances       = var.max_instances
  initial_admin_email = var.initial_admin_email

  env = {
    INVENTORY_API_BASE_URL = module.food_vault.service_uri
    INVENTORY_WAREHOUSE_ID = var.inventory_warehouse_id
  }

  secret_env = {
    INVENTORY_API_TOKEN = google_secret_manager_secret.inventory_api_token.secret_id
  }

  depends_on = [google_secret_manager_secret_version.inventory_api_token]
}
