# N01（Terraform 版）：グローバル証明書をリージョン内部 ALB のプロキシに設定すると失敗することの確認
# 親ディレクトリの環境（um-tokyo、neg-cert-global-sm）が前提。別 state。
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0, < 8.0"
    }
  }
}

variable "project_id" {
  type = string
}

provider "google" {
  project = var.project_id
}

resource "google_compute_region_target_https_proxy" "neg_global_cert" {
  name                             = "neg-proxy-tf"
  region                           = "asia-northeast1"
  url_map                          = "projects/${var.project_id}/regions/asia-northeast1/urlMaps/um-tokyo"
  certificate_manager_certificates = ["projects/${var.project_id}/locations/global/certificates/neg-cert-global-sm"]
}
