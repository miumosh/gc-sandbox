variable "project_id" {
  description = "検証用プロジェクト ID"
  type        = string
}

variable "ca_tier" {
  description = "CA プールの階層。設計書は ENTERPRISE。費用を抑える場合は DEVOPS"
  type        = string
  default     = "ENTERPRISE"
  validation {
    condition     = contains(["ENTERPRISE", "DEVOPS"], var.ca_tier)
    error_message = "ENTERPRISE か DEVOPS を指定する。"
  }
}

variable "fqdn" {
  description = "業務で使う FQDN（両リージョン共通）"
  type        = string
  default     = "test.sample.com"
}

variable "dns_zone_name" {
  description = "限定公開ゾーンの DNS 名"
  type        = string
  default     = "sample.com."
}

variable "regions" {
  description = "リージョンごとの値。キー tokyo / osaka は固定"
  type = map(object({
    region          = string
    zone            = string
    subnet_cidr     = string
    proxy_only_cidr = string
    vip             = string
    regional_fqdn   = string
  }))
  default = {
    tokyo = {
      region          = "asia-northeast1"
      zone            = "asia-northeast1-a"
      subnet_cidr     = "10.10.0.0/24"
      proxy_only_cidr = "10.10.100.0/23"
      vip             = "10.10.0.10"
      regional_fqdn   = "tokyo.test.sample.com"
    }
    osaka = {
      region          = "asia-northeast2"
      zone            = "asia-northeast2-a"
      subnet_cidr     = "10.20.0.0/24"
      proxy_only_cidr = "10.20.100.0/23"
      vip             = "10.20.0.10"
      regional_fqdn   = "osaka.test.sample.com"
    }
  }
}

variable "backend_size" {
  description = "リージョンごとの業務サーバ台数（MIG のサイズ）"
  type        = number
  default     = 2
}

variable "issuance_lifetime" {
  description = "発行構成の証明書有効期間（gcloud の既定値 P30D と同じ）"
  type        = string
  default     = "2592000s"
}

variable "rotation_window_percentage" {
  description = "更新開始のタイミング（gcloud の既定値 66 と同じ）"
  type        = number
  default     = 66
}

variable "client_ssh_public_key" {
  description = "クライアント VM にだけ登録する SSH 公開鍵（\"user:ssh-ed25519 ...\" 形式）。空なら登録しない"
  type        = string
  default     = ""
}
