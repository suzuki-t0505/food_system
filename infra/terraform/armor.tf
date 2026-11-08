# 両バックエンド共通のセキュリティポリシー。評価は priority の小さい順で、最初に一致したルールで決まる
locals {
  waf_rules = {
    1000 = "sqli-v33-stable"
    1001 = "xss-v33-stable"
    1002 = "lfi-v33-stable"
    1003 = "rfi-v33-stable"
    1004 = "rce-v33-stable"
    1005 = "scannerdetection-v33-stable"
    1006 = "protocolattack-v33-stable"
  }

  restrict_source = length(var.allowed_source_ranges) > 0
}

resource "google_compute_security_policy" "this" {
  name        = "food-system"
  description = "food_vault / food_ship の LB 用"
  type        = "CLOUD_ARMOR"

  # 在庫 API は外部から使わせない(発送からは VPC 経由で *.run.app を直接呼ぶ)。
  # Plug は空のパス要素を無視し、パス要素を URL デコードするため、"//api" や "%61pi" も対象にする
  # (Cloud Armor の式には urlDecode() の関数形式が無いため、a/p/i のパーセントエンコードを正規表現で列挙する)
  rule {
    priority    = 100
    action      = "deny(403)"
    description = "在庫 API(/api)を外部から遮断"

    match {
      expr {
        expression = "request.path.lower().matches('^/+(a|%61)(p|%70)(i|%69)(/|$)')"
      }
    }
  }

  dynamic "rule" {
    for_each = local.waf_rules

    content {
      priority    = rule.key
      action      = "deny(403)"
      description = "WAF: ${rule.value}"

      match {
        expr {
          expression = "evaluatePreconfiguredWaf('${rule.value}', {'sensitivity': 1})"
        }
      }
    }
  }

  # IP ごとのレート制限。許可された送信元(未指定なら全員)はここで通す
  rule {
    priority    = 2000
    action      = "throttle"
    description = "IP ごとのレート制限"

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = local.restrict_source ? var.allowed_source_ranges : ["*"]
      }
    }

    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"

      rate_limit_threshold {
        count        = var.rate_limit_per_minute
        interval_sec = 60
      }
    }
  }

  # 既定: 送信元を絞る場合は拒否、絞らない場合は許可(ここに来るのは前段のルールに一致しなかったものだけ)
  rule {
    priority    = 2147483647
    action      = local.restrict_source ? "deny(403)" : "allow"
    description = "既定のルール"

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }
  }

  depends_on = [google_project_service.this]
}
