variable "project_id" {
  description = "GCP プロジェクト ID"
  type        = string
}

variable "region" {
  description = "Cloud Run / Cloud SQL / Artifact Registry のリージョン"
  type        = string
  default     = "asia-northeast1"
}

variable "domain" {
  description = "公開する独自ドメイン。ホスト名は <vault_subdomain>.<domain> / <ship_subdomain>.<domain>"
  type        = string
}

variable "vault_subdomain" {
  description = "在庫管理システムのサブドメイン"
  type        = string
  default     = "vault"
}

variable "ship_subdomain" {
  description = "発送システムのサブドメイン"
  type        = string
  default     = "ship"
}

variable "food_vault_image_tag" {
  description = "Artifact Registry の food_vault イメージのタグ(初回作成用。以降のイメージ更新は GitHub Actions が行い、Terraform は無視する)"
  type        = string
}

variable "food_ship_image_tag" {
  description = "Artifact Registry の food_ship イメージのタグ(初回作成用。以降のイメージ更新は GitHub Actions が行い、Terraform は無視する)"
  type        = string
}

variable "initial_admin_email" {
  description = "初期管理者のメールアドレス(両アプリ共通。パスワードは Secret Manager に生成)"
  type        = string
}

variable "db_tier" {
  description = "Cloud SQL のマシンタイプ(共有コアの最小。不足したら db-g1-small や db-custom-1-3840 へ)"
  type        = string
  default     = "db-f1-micro"
}

variable "deletion_protection" {
  description = "Cloud SQL の削除保護"
  type        = bool
  default     = true
}

variable "min_instances" {
  description = "Cloud Run の最小インスタンス数"
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Cloud Run の最大インスタンス数"
  type        = number
  default     = 2
}

variable "allowed_source_ranges" {
  description = "LB へのアクセスを許可する送信元 CIDR。空なら全許可"
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.allowed_source_ranges) <= 10
    error_message = "Cloud Armor の 1 ルールに指定できる CIDR は 10 件までです。"
  }
}

variable "rate_limit_per_minute" {
  description = "送信元 IP ごとの 1 分あたりのリクエスト上限(超過は 429)"
  type        = number
  default     = 600
}

variable "github_repository" {
  description = "GitHub Actions からのデプロイを許可するリポジトリ(owner/repo)"
  type        = string
  default     = "suzuki-t0505/food_system"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository は owner/repo 形式で指定してください。"
  }
}

variable "github_deploy_branch" {
  description = "自動デプロイを許可するブランチ(このブランチ上のワークフローだけが WIF で認証できる)"
  type        = string
  default     = "dev"

  validation {
    condition     = length(var.github_deploy_branch) > 0
    error_message = "github_deploy_branch は空にできません。"
  }
}

variable "inventory_warehouse_id" {
  description = "発送システムの対象倉庫 ID(段階 4 で使う)"
  type        = string
  default     = ""
}
