# Datadog GCP インテグレーション（STS: Datadog の SA が本 SA を借用。SA キーは発行しない）
locals {
  integration_enabled = var.enable_gcp_integration ? 1 : 0
}

resource "google_project_service" "integration" {
  for_each = var.enable_gcp_integration ? toset([
    "cloudresourcemanager.googleapis.com",
    "cloudasset.googleapis.com",
    "monitoring.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
  ]) : toset([])

  service            = each.value
  disable_on_destroy = false
}

resource "google_service_account" "datadog" {
  count = local.integration_enabled

  account_id   = "${var.name_prefix}-datadog"
  display_name = "Datadog integration (read only)"
}

resource "google_project_iam_member" "datadog" {
  for_each = var.enable_gcp_integration ? toset([
    "roles/monitoring.viewer",
    "roles/compute.viewer",
    "roles/cloudasset.viewer",
    "roles/browser",
  ]) : toset([])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.datadog[0].email}"
}

# Datadog 側の委任用 SA（組織ごとに固定）
resource "datadog_integration_gcp_sts" "this" {
  count = local.integration_enabled

  client_email                = google_service_account.datadog[0].email
  resource_collection_enabled = true
  automute                    = false # 停止した VM のモニターを自動ミュートしない（停止検知の検証のため）

  depends_on = [google_project_iam_member.datadog]
}

resource "google_service_account_iam_member" "datadog_token_creator" {
  count = local.integration_enabled

  service_account_id = google_service_account.datadog[0].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${datadog_integration_gcp_sts.this[0].delegate_account_email}"
}
