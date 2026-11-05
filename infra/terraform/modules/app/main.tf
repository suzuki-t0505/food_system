# 1 アプリ分: DB・DB ユーザー・秘密・サービスアカウント・Cloud Run サービス・Cloud Run Job

# --- DB ---

resource "google_sql_database" "this" {
  name     = var.otp_app
  instance = var.sql_instance_name
}

resource "random_password" "db" {
  length  = 32
  special = false # DATABASE_URL に埋め込むため URL で特別な意味を持つ文字を避ける
}

resource "google_sql_user" "this" {
  name     = var.otp_app
  instance = var.sql_instance_name
  password = random_password.db.result
}

# --- 秘密 ---

resource "random_password" "secret_key_base" {
  length  = 64
  special = false
}

resource "random_password" "initial_admin" {
  length  = 24
  special = false
}

locals {
  secrets = {
    DATABASE_URL           = "ecto://${google_sql_user.this.name}:${random_password.db.result}@${var.sql_private_ip}/${google_sql_database.this.name}"
    SECRET_KEY_BASE        = random_password.secret_key_base.result
    INITIAL_ADMIN_PASSWORD = random_password.initial_admin.result
  }

  secret_ids = {
    DATABASE_URL           = "${var.name}-database-url"
    SECRET_KEY_BASE        = "${var.name}-secret-key-base"
    INITIAL_ADMIN_PASSWORD = "${var.name}-initial-admin-password"
  }
}

resource "google_secret_manager_secret" "this" {
  for_each = local.secret_ids

  secret_id = each.value

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "this" {
  for_each = local.secret_ids

  secret      = google_secret_manager_secret.this[each.key].id
  secret_data = local.secrets[each.key]
}

# --- サービスアカウント(サービスと Job で共用) ---

resource "google_service_account" "this" {
  account_id   = "${var.name}-run"
  display_name = "${var.otp_app} (Cloud Run)"
}

resource "google_secret_manager_secret_iam_member" "own" {
  for_each = local.secret_ids

  secret_id = google_secret_manager_secret.this[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.this.member
}

resource "google_secret_manager_secret_iam_member" "shared" {
  for_each = var.secret_env

  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.this.member
}

resource "google_project_iam_member" "cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.this.member
}

# --- 環境変数 ---

locals {
  # サービス・Job 共通(平文)
  common_env = merge({
    PHX_HOST  = var.host
    POOL_SIZE = tostring(var.pool_size)
  }, var.env)

  # サービス・Job 共通(秘密)
  common_secret_env = merge({
    DATABASE_URL    = google_secret_manager_secret.this["DATABASE_URL"].secret_id
    SECRET_KEY_BASE = google_secret_manager_secret.this["SECRET_KEY_BASE"].secret_id
  }, var.secret_env)

  job_env = merge(local.common_env, {
    INITIAL_ADMIN_EMAIL = var.initial_admin_email
  })

  job_secret_env = merge(local.common_secret_env, {
    INITIAL_ADMIN_PASSWORD = google_secret_manager_secret.this["INITIAL_ADMIN_PASSWORD"].secret_id
  })
}

# --- Cloud Run サービス ---

resource "google_cloud_run_v2_service" "this" {
  name                = var.name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  deletion_protection = false

  # 外部からの到達は ingress(LB・VPC 内のみ)で制限し、Cloud Run の IAM 認証は使わない
  invoker_iam_disabled = true

  template {
    service_account = google_service_account.this.email
    timeout         = "3600s" # LiveView の WebSocket
    # Endpoint は IPv6 の全アドレス({0,0,0,0,0,0,0,0})で待ち受けるため、Linux 互換の第 2 世代を使う
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    vpc_access {
      egress = var.egress

      network_interfaces {
        network    = var.network
        subnetwork = var.subnetwork
      }
    }

    containers {
      image = var.image

      ports {
        container_port = 4000
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }

      env {
        name  = "PHX_SERVER"
        value = "true"
      }

      dynamic "env" {
        for_each = local.common_env

        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.common_secret_env

        content {
          name = env.key

          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      startup_probe {
        tcp_socket {
          port = 4000
        }
        period_seconds    = 5
        failure_threshold = 24
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.own,
    google_secret_manager_secret_iam_member.shared,
    google_secret_manager_secret_version.this,
  ]
}

# --- Cloud Run Job(マイグレーション → シード) ---

resource "google_cloud_run_v2_job" "migrate" {
  name                = "${var.name}-migrate"
  location            = var.region
  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account       = google_service_account.this.email
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      max_retries           = 0
      timeout               = "600s"

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"

        network_interfaces {
          network    = var.network
          subnetwork = var.subnetwork
        }
      }

      containers {
        image   = var.image
        command = ["/app/bin/${var.otp_app}"]
        args    = ["eval", "${var.release_module}.Release.migrate_and_seed()"]

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }

        dynamic "env" {
          for_each = local.job_env

          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = local.job_secret_env

          content {
            name = env.key

            value_source {
              secret_key_ref {
                secret  = env.value
                version = "latest"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.own,
    google_secret_manager_secret_iam_member.shared,
    google_secret_manager_secret_version.this,
  ]
}
