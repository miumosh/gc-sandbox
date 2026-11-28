terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0, < 8.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 7.0, < 8.0"
    }
  }

  # 検証用のためローカル state（.gitignore 済み）
}

provider "google" {
  project = var.project_id
  default_labels = {
    purpose = "drtest"
  }
}

provider "google-beta" {
  project = var.project_id
  default_labels = {
    purpose = "drtest"
  }
}
