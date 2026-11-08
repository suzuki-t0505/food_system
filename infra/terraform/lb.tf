# グローバル外部アプリケーション LB(TLS 終端・ホスト名で振り分け。HTTP(80)は待ち受けない)

locals {
  backends = {
    vault = { service = module.food_vault.service_name, host = local.vault_host }
    ship  = { service = module.food_ship.service_name, host = local.ship_host }
  }
}

resource "google_compute_global_address" "lb" {
  name = "food-system-lb"

  depends_on = [google_project_service.this]
}

resource "google_compute_managed_ssl_certificate" "this" {
  name = "food-system"

  managed {
    domains = [local.vault_host, local.ship_host]
  }

  depends_on = [google_project_service.this]
}

resource "google_compute_region_network_endpoint_group" "this" {
  for_each = local.backends

  name                  = "food-${each.key}-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = each.value.service
  }
}

resource "google_compute_backend_service" "this" {
  for_each = local.backends

  name                  = "food-${each.key}"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"
  security_policy       = google_compute_security_policy.this.id

  backend {
    group = google_compute_region_network_endpoint_group.this[each.key].id
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "https" {
  name = "food-system-https"

  # どのホストにも一致しない(IP 直打ちなど)は在庫のホストへリダイレクトする
  default_url_redirect {
    host_redirect          = local.vault_host
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = true
  }

  dynamic "host_rule" {
    for_each = local.backends

    content {
      hosts        = [host_rule.value.host]
      path_matcher = host_rule.key
    }
  }

  dynamic "path_matcher" {
    for_each = local.backends

    content {
      name            = path_matcher.key
      default_service = google_compute_backend_service.this[path_matcher.key].id
    }
  }
}

resource "google_compute_target_https_proxy" "this" {
  name             = "food-system-https"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.this.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "food-system-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.this.id
}

# コスト削減のため HTTP(80)は待ち受けない(http:// では接続できない)
