# Cloud Scheduler から Compute Engine API を OAuth で直接呼び出して起動・停止する
resource "google_service_account" "scheduler" {
  account_id   = "${var.name_prefix}-scheduler"
  display_name = "Cloud Scheduler VM start/stop SA"

  depends_on = [google_project_service.this]
}

# 最小権限のカスタムロール
resource "google_project_iam_custom_role" "vm_start_stop" {
  role_id     = "${var.name_prefix}VmStartStop"
  title       = "VM start/stop (vm-alb-scheduler)"
  permissions = ["compute.instances.start", "compute.instances.stop"]

  depends_on = [google_project_service.this]
}

# 対象 VM 単位で付与
resource "google_compute_instance_iam_member" "scheduler" {
  for_each = var.grant_scheduler_permission ? var.instances : {}

  zone          = each.value
  instance_name = google_compute_instance.web[each.key].name
  role          = google_project_iam_custom_role.vm_start_stop.id
  member        = "serviceAccount:${google_service_account.scheduler.email}"
}

locals {
  scheduler_jobs = merge([
    for vm, zone in var.instances : {
      for action, schedule in { start = var.start_schedule, stop = var.stop_schedule } :
      "${vm}-${action}" => {
        vm       = vm
        zone     = zone
        action   = action
        schedule = schedule
      }
    }
  ]...)
}

resource "google_cloud_scheduler_job" "vm" {
  for_each = local.scheduler_jobs

  name             = "${var.name_prefix}-${each.key}"
  description      = "${each.value.action} ${google_compute_instance.web[each.value.vm].name}"
  region           = var.region
  schedule         = each.value.schedule
  time_zone        = var.scheduler_time_zone
  paused           = var.scheduler_paused
  attempt_deadline = "60s"

  retry_config {
    retry_count = 0 # 失敗を即座にログに出す
  }

  http_target {
    http_method = "POST"
    uri         = "https://compute.googleapis.com/compute/v1/projects/${var.project_id}/zones/${each.value.zone}/instances/${google_compute_instance.web[each.value.vm].name}/${each.value.action}"

    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
}

# 失敗再現用: 存在しない VM を起動しようとして 404 になるジョブ（手動実行専用）
resource "google_cloud_scheduler_job" "failure_test" {
  count = var.enable_failure_test_job ? 1 : 0

  name             = "${var.name_prefix}-failure-test"
  description      = "FAILURE TEST: start non-existent instance (expect NOT_FOUND)"
  region           = var.region
  schedule         = "0 0 1 1 *" # 年1回。検証では手動実行する（一時停止中ジョブの手動実行可否に依存しないよう paused にしない）
  time_zone        = var.scheduler_time_zone
  attempt_deadline = "60s"

  retry_config {
    retry_count = 0
  }

  http_target {
    http_method = "POST"
    uri         = "https://compute.googleapis.com/compute/v1/projects/${var.project_id}/zones/${values(var.instances)[0]}/instances/${var.name_prefix}-does-not-exist/start"

    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
}
