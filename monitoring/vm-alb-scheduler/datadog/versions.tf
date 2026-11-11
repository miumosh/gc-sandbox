terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
    datadog = {
      source  = "DataDog/datadog"
      version = ">= 3.40, < 5.0"
    }
  }

  # 検証用のためローカル state（.gitignore 済み）
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# 認証情報は環境変数で渡す（tfvars / コードに書かない）
#   export DD_API_KEY=...  DD_APP_KEY=...
provider "datadog" {
  api_url = "https://api.${var.datadog_site}/"
}
