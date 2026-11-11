variable "project_id" {
  description = "検証用 GCP プロジェクト ID"
  type        = string
}

variable "region" {
  description = "リージョン"
  type        = string
  default     = "asia-northeast1"
}

variable "name_prefix" {
  description = "リソース名の接頭辞"
  type        = string
  default     = "vas" # vm-alb-scheduler
}

# ---- Network ----
variable "nw_subnet_cidr" {
  description = "NW 用サブネット（LB フロントエンド VIP など）"
  type        = string
  default     = "10.10.0.0/24"
}

variable "ilb_vip_address" {
  description = "内部 ALB のフロントエンド VIP（NW 用サブネット内の固定プライベート IP）"
  type        = string
  default     = "10.10.0.10"
}

variable "proxy_only_subnet_cidr" {
  description = "プロキシ専用サブネット（推奨 /23、最小 /26）"
  type        = string
  default     = "10.10.64.0/23"
}

variable "app_subnet_cidr" {
  description = "アプリ用サブネット（バックエンド VM）"
  type        = string
  default     = "10.10.1.0/24"
}

variable "enable_test_client" {
  description = "NW 用サブネットに試験クライアント VM を作成する（内部 VIP への curl 用）"
  type        = bool
  default     = true
}

variable "client_traffic_enabled" {
  description = "試験クライアントから VIP へ常時トラフィック（2 秒間隔）を流す"
  type        = bool
  default     = true
}

# ---- Compute ----
variable "instances" {
  description = "ALB 配下の VM（名前サフィックス => ゾーン）"
  type        = map(string)
  default = {
    "web-1" = "asia-northeast1-a"
    "web-2" = "asia-northeast1-b"
  }
}

variable "machine_type" {
  type    = string
  default = "e2-micro"
}

variable "notification_email" {
  description = "アラート通知先メールアドレス（terraform.tfvars に記載。Git 管理外）"
  type        = string
  sensitive   = true
}

# ---- Cloud Scheduler ----
variable "scheduler_time_zone" {
  type    = string
  default = "Asia/Tokyo"
}

variable "start_schedule" {
  description = "VM 起動の cron"
  type        = string
  default     = "0 9 * * 1-5"
}

variable "stop_schedule" {
  description = "VM 停止の cron"
  type        = string
  default     = "0 19 * * 1-5"
}

variable "scheduler_paused" {
  description = "true で起動停止ジョブを一時停止状態で作成する（検証中に自動実行させたくない場合）"
  type        = bool
  default     = false
}

variable "grant_scheduler_permission" {
  description = "false にすると Scheduler SA の VM 起動停止権限を外し、403 失敗を再現できる"
  type        = bool
  default     = true
}

variable "enable_failure_test_job" {
  description = "存在しない VM を対象にした失敗再現用ジョブ（404）を作成する"
  type        = bool
  default     = true
}

# ---- Monitoring ----
variable "enable_gcp_alert_policies" {
  description = "Cloud Monitoring のアラートポリシーを作成する（Datadog と比較するため。ログベース指標は Datadog 連携でも使うため常に作成する）"
  type        = bool
  default     = true
}

variable "enable_uptime_check" {
  description = "内部 VIP へのプライベート Uptime Check（Service Directory 経由）を作成する"
  type        = bool
  default     = true
}

variable "log_alert_rate_limit" {
  description = "ログベースアラートの通知間隔の下限"
  type        = string
  default     = "300s"
}

variable "alert_auto_close" {
  description = "インシデント自動クローズまでの時間"
  type        = string
  default     = "1800s"
}
