terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }

  # 検証用のためローカル state（.gitignore 済み）。共有する場合は GCS backend に切り替える。
}

provider "google" {
  project = var.project_id
  region  = var.region
}
