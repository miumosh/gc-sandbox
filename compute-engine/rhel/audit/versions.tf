terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }

  # 検証用のためローカル state（.gitignore 済み）
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
