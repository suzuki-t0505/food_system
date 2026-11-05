variable "name" {
  description = "リソース名の接頭辞(例: food-vault)"
  type        = string
}

variable "otp_app" {
  description = "OTP アプリ名(例: food_vault)。DB 名・DB ユーザー名・リリースのコマンド名に使う"
  type        = string
}

variable "release_module" {
  description = "Release モジュールの接頭辞(例: FoodVault)"
  type        = string
}

variable "image" {
  description = "コンテナイメージ"
  type        = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "network" {
  description = "Direct VPC egress の VPC(id)"
  type        = string
}

variable "subnetwork" {
  description = "Direct VPC egress のサブネット(id)"
  type        = string
}

variable "egress" {
  description = "Direct VPC egress の範囲(PRIVATE_RANGES_ONLY / ALL_TRAFFIC)"
  type        = string
  default     = "PRIVATE_RANGES_ONLY"
}

variable "sql_instance_name" {
  type = string
}

variable "sql_private_ip" {
  type = string
}

variable "host" {
  description = "公開ホスト名(PHX_HOST)"
  type        = string
}

variable "min_instances" {
  type = number
}

variable "max_instances" {
  type = number
}

variable "pool_size" {
  description = "Ecto の接続プールサイズ(インスタンスあたり)"
  type        = number
  default     = 5
}

variable "env" {
  description = "サービスと Job に渡す追加の環境変数(平文)"
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "サービスと Job に渡す追加の環境変数(値は Secret Manager の secret_id。最新バージョンを参照)"
  type        = map(string)
  default     = {}
}

variable "initial_admin_email" {
  type = string
}
