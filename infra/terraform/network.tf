resource "google_compute_network" "this" {
  name                    = "food-system"
  auto_create_subnetworks = false

  depends_on = [google_project_service.this]
}

# Cloud Run の Direct VPC egress 用。発送 → 在庫(*.run.app)を内部トラフィックにするため Private Google Access を有効にする
resource "google_compute_subnetwork" "run" {
  name                     = "food-system-run"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = "10.10.0.0/24"
  private_ip_google_access = true
}

# Cloud SQL のプライベート IP 用(プライベートサービス接続)
resource "google_compute_global_address" "private_services" {
  name          = "food-system-private-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "this" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
  deletion_policy         = "ABANDON"
}
