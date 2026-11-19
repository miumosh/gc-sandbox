variable "project_id" {
  description = "検証用 GCP プロジェクト ID"
  type        = string
}

variable "region" {
  type    = string
  default = "asia-northeast1"
}

variable "zone" {
  type    = string
  default = "asia-northeast1-a"
}

variable "name_prefix" {
  description = "リソース名の接頭辞"
  type        = string
  default     = "rha" # rhel-audit
}

variable "subnet_cidr" {
  type    = string
  default = "10.20.0.0/24"
}

variable "machine_type" {
  description = "RHEL は 2GB 以上を推奨するため e2-medium（2 vCPU / 4GB）"
  type        = string
  default     = "e2-medium"
}

variable "image" {
  description = "RHEL イメージ（ファミリー指定）。顧客環境に合わせて rhel-8 / rhel-10 に変更可"
  type        = string
  default     = "rhel-cloud/rhel-9"
}

variable "allowed_ssh_cidr" {
  description = "SSH を許可する送信元（自宅のグローバル IP/32）。terraform.tfvars に記載（Git 管理外）"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^\\d{1,3}(\\.\\d{1,3}){3}/32$", var.allowed_ssh_cidr))
    error_message = "allowed_ssh_cidr は x.x.x.x/32 の形式で 1 アドレスだけ指定してください。"
  }
}

variable "ssh_user" {
  description = "VM に作成するログインユーザー（metadata ssh-keys で作成。sudo 可）"
  type        = string
  default     = "rheladmin"
}

variable "ssh_public_key_path" {
  description = "SSH 公開鍵のパス（本検証専用の鍵。リポジトリの外に置く）"
  type        = string
  default     = "~/.ssh/gc-rhel-audit.pub"
}
