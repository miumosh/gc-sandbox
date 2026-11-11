# ---- GCP（親ディレクトリの `terraform output datadog_inputs` から転記）----
variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-northeast1"
}

variable "name_prefix" {
  type    = string
  default = "vas"
}

variable "network_name" {
  type    = string
  default = "vas-vpc"
}

variable "forwarding_rule_name" {
  description = "内部 ALB の転送ルール名（LB ログ / 指標の絞り込みに使用。内部 ALB のログ・指標には backend_service_name ラベルは無い）"
  type        = string
  default     = "vas-fr-http"
}

variable "instance_names" {
  type    = list(string)
  default = ["vas-web-1", "vas-web-2"]
}

variable "hc_unhealthy_metric" {
  type    = string
  default = "vas_hc_unhealthy_count"
}

variable "scheduler_failed_metric" {
  type    = string
  default = "vas_scheduler_failed_count"
}

variable "compute_op_failed_metric" {
  type    = string
  default = "vas_compute_op_failed_count"
}

variable "uptime_check_id" {
  description = "親側のプライベート Uptime Check ID（null なら DD-A4 を作らない）"
  type        = string
  default     = null
}

# ---- Datadog ----
variable "datadog_site" {
  description = "Datadog サイト（例: ap1.datadoghq.com / datadoghq.com）"
  type        = string
  default     = "ap1.datadoghq.com"
}

variable "notify" {
  description = "モニター通知先ハンドル（例: \"@you@example.com\" や \"@slack-channel\"）"
  type        = string
}

variable "enable_gcp_integration" {
  description = "Datadog GCP インテグレーション（STS / キーレス）を作成する。既に手動連携済みなら false"
  type        = bool
  default     = true
}

variable "enable_log_forwarding" {
  description = "GCP ログを Pub/Sub + Dataflow 経由で Datadog へ転送する（Datadog ログモニター用。Dataflow の常時課金あり）"
  type        = bool
  default     = false
}

variable "dataflow_subnet_cidr" {
  description = "Dataflow ワーカー用サブネット（ログ転送有効時のみ作成）"
  type        = string
  default     = "10.10.2.0/24"
}

variable "evaluation_window" {
  description = "モニターの評価ウィンドウ"
  type        = string
  default     = "last_10m"
}
