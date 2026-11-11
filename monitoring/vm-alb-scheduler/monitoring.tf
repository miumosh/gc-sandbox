locals {
  hc_log_name    = "projects/${var.project_id}/logs/compute.googleapis.com%2Fhealthchecks"
  audit_log_name = "projects/${var.project_id}/logs/cloudaudit.googleapis.com%2Factivity"

  alerts_enabled = var.enable_gcp_alert_policies ? 1 : 0

  # [A1/A3] ヘルスチェックで HEALTHY -> UNHEALTHY に遷移したログ
  #   遷移ログは詳細状態（UNKNOWN->TIMEOUT 等）の変化でも出るため previousHealthState で絞る（起動直後の誤検知防止）
  hc_unhealthy_filter = <<-EOT
    logName="${local.hc_log_name}"
    resource.type="gce_instance_group"
    jsonPayload.healthCheckProbeResult.healthState="UNHEALTHY"
    jsonPayload.healthCheckProbeResult.previousHealthState="HEALTHY"
  EOT

  # [A2] 内部 ALB が 5xx を返したリクエストログ
  #   検証結果: 内部 ALB のログには statusDetails が無く、全台停止時は status=503 / backend_name="" となる
  lb_no_backend_filter = <<-EOT
    resource.type="internal_http_lb_rule"
    resource.labels.forwarding_rule_name="${google_compute_forwarding_rule.http.name}"
    httpRequest.status>=500
  EOT

  # [A7] VM 停止オペレーション完了（監査ログ）
  vm_stopped_filter = <<-EOT
    logName="${local.audit_log_name}"
    resource.type="gce_instance"
    protoPayload.methodName=~"compute\.instances\.stop$"
    operation.last=true
  EOT

  # [S1/S2] Cloud Scheduler ジョブ実行の失敗ログ
  scheduler_failed_filter = <<-EOT
    resource.type="cloud_scheduler_job"
    jsonPayload."@type"="type.googleapis.com/google.cloud.scheduler.logging.AttemptFinished"
    severity>=ERROR
  EOT

  # [S3] API 受付後に Compute の start/stop オペレーション自体が失敗（監査ログ）
  compute_op_failed_filter = <<-EOT
    logName="${local.audit_log_name}"
    resource.type="gce_instance"
    protoPayload.methodName=~"compute\.instances\.(start|stop)$"
    severity>=ERROR
  EOT
}

resource "google_monitoring_notification_channel" "email" {
  count = local.alerts_enabled

  display_name = "${var.name_prefix} alert email"
  type         = "email"
  labels = {
    email_address = var.notification_email
  }

  depends_on = [google_project_service.this]
}

########################################
# ログベース指標（GCP アラートと Datadog の両方で利用）
########################################

resource "google_logging_metric" "hc_unhealthy" {
  name   = "${var.name_prefix}_hc_unhealthy_count"
  filter = local.hc_unhealthy_filter

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_service.this]
}

resource "google_logging_metric" "scheduler_failed" {
  name   = "${var.name_prefix}_scheduler_failed_count"
  filter = local.scheduler_failed_filter

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key        = "job_id"
      value_type = "STRING"
    }
  }

  label_extractors = {
    job_id = "EXTRACT(resource.labels.job_id)"
  }

  depends_on = [google_project_service.this]
}

resource "google_logging_metric" "compute_op_failed" {
  name   = "${var.name_prefix}_compute_op_failed_count"
  filter = local.compute_op_failed_filter

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_service.this]
}

########################################
# ALB 配下 VM の停止検知
########################################

# [A1] ログベースアラート: ヘルスチェックログ UNHEALTHY 遷移（1台停止でも検知）
resource "google_monitoring_alert_policy" "a1_hc_unhealthy_log" {
  count = local.alerts_enabled

  display_name = "[A1][log] ILB backend UNHEALTHY (health check log)"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Health check transitioned to UNHEALTHY"
    condition_matched_log {
      filter = local.hc_unhealthy_filter
      label_extractors = {
        ip_address     = "EXTRACT(jsonPayload.healthCheckProbeResult.ipAddress)"
        detailed_state = "EXTRACT(jsonPayload.healthCheckProbeResult.detailedHealthState)"
      }
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = var.log_alert_rate_limit
    }
    auto_close = var.alert_auto_close
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]

  documentation {
    mime_type = "text/markdown"
    content   = "内部 ALB のヘルスチェックでバックエンド VM が UNHEALTHY に遷移しました。VM の停止・アプリ停止を確認してください。"
  }
}

# [A2] ログベースアラート: 内部 ALB リクエストログ 5xx（全台停止 / アプリ停止直後の数秒）
resource "google_monitoring_alert_policy" "a2_lb_no_backend_log" {
  count = local.alerts_enabled

  display_name = "[A2][log] ILB 5xx responses (request log)"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "ILB returned 5xx"
    condition_matched_log {
      filter = local.lb_no_backend_filter
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = var.log_alert_rate_limit
    }
    auto_close = var.alert_auto_close
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]

  documentation {
    mime_type = "text/markdown"
    content   = "内部 ALB が 5xx を返しました（全台停止: failed_to_pick_backend / アプリ停止直後: failed_to_connect_to_backend）。"
  }
}

# [A3] 指標アラート: ログベース指標 UNHEALTHY 遷移数
#   ヘルスチェックログの resource.type=gce_instance_group は Monitoring のリソース型に存在しないため、
#   ログベース指標は resource.type=global として記録される（検証で確認済み）
resource "google_monitoring_alert_policy" "a3_hc_unhealthy_metric" {
  count = local.alerts_enabled

  display_name = "[A3][metric] ILB backend UNHEALTHY (log-based metric)"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "hc_unhealthy_count > 0"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.hc_unhealthy.name}\" AND resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = var.alert_auto_close
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}

# [A5] 指標アラート: VM の uptime 指標の途絶（VM 単位で停止を検知）
resource "google_monitoring_alert_policy" "a5_vm_uptime_absent" {
  count = local.alerts_enabled

  display_name = "[A5][metric] VM stopped (instance/uptime absent)"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "instance/uptime absent for 3m"
    condition_absent {
      filter   = "metric.type=\"compute.googleapis.com/instance/uptime\" AND resource.type=\"gce_instance\" AND metric.label.instance_name=monitoring.regex.full_match(\"${var.name_prefix}-web-.*\")"
      duration = "180s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MEAN"
        cross_series_reducer = "REDUCE_MEAN"
        group_by_fields      = ["metric.label.instance_name"]
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = var.alert_auto_close
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}

# [A6] 指標アラート: 内部 ALB のバックエンド（IG）別リクエスト数の途絶（ALB 視点で 1 台停止を検知）
#   前提: 常時トラフィックがあること（本検証では試験クライアントが 2 秒間隔で送信）
resource "google_monitoring_alert_policy" "a6_backend_requests_absent" {
  count = local.alerts_enabled

  display_name = "[A6][metric] ILB backend receives no requests (backend_request_count absent)"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "backend_request_count absent for 3m"
    condition_absent {
      filter   = "metric.type=\"loadbalancing.googleapis.com/https/internal/backend_request_count\" AND resource.type=\"internal_http_lb_rule\" AND resource.label.forwarding_rule_name=\"${google_compute_forwarding_rule.http.name}\" AND resource.label.backend_name=monitoring.regex.full_match(\".+\")"
      duration = "180s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.backend_name"]
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = var.alert_auto_close
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}

# [A7] ログベースアラート: VM 停止オペレーション完了（監査ログ。計画停止でも発報）
resource "google_monitoring_alert_policy" "a7_vm_stopped_audit_log" {
  count = local.alerts_enabled

  display_name = "[A7][log] VM stopped (audit log)"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "compute.instances.stop completed"
    condition_matched_log {
      filter = local.vm_stopped_filter
      label_extractors = {
        instance  = "EXTRACT(protoPayload.resourceName)"
        principal = "EXTRACT(protoPayload.authenticationInfo.principalEmail)"
      }
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = var.log_alert_rate_limit
    }
    auto_close = var.alert_auto_close
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}

# [A4] プライベート Uptime Check（VPC 内の Google チェッカーから内部 VIP へ）
data "google_project" "this" {
  project_id = var.project_id
}

resource "google_service_directory_namespace" "uptime" {
  count = var.enable_uptime_check ? 1 : 0

  namespace_id = "${var.name_prefix}-uptime"
  location     = var.region

  depends_on = [google_project_service.this]
}

resource "google_service_directory_service" "ilb" {
  count = var.enable_uptime_check ? 1 : 0

  service_id = "${var.name_prefix}-ilb"
  namespace  = google_service_directory_namespace.uptime[0].id
}

resource "google_service_directory_endpoint" "ilb" {
  count = var.enable_uptime_check ? 1 : 0

  endpoint_id = "${var.name_prefix}-ilb-vip"
  service     = google_service_directory_service.ilb[0].id
  address     = google_compute_address.ilb_vip.address
  port        = 80
  network     = "projects/${data.google_project.this.number}/locations/global/networks/${google_compute_network.vpc.name}"
}

# Monitoring サービスエージェントが Service Directory を参照できるようにする
resource "google_project_iam_member" "uptime_sd" {
  for_each = var.enable_uptime_check ? toset([
    "roles/servicedirectory.viewer",
    "roles/servicedirectory.pscAuthorizedService",
  ]) : toset([])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
}

resource "google_monitoring_uptime_check_config" "ilb" {
  count = var.enable_uptime_check ? 1 : 0

  display_name = "${var.name_prefix}-ilb-http-private"
  timeout      = "10s"
  period       = "60s"
  checker_type = "VPC_CHECKERS"

  http_check {
    path    = "/"
    port    = 80
    use_ssl = false
  }

  monitored_resource {
    type = "servicedirectory_service"
    labels = {
      project_id     = var.project_id
      location       = var.region
      namespace_name = google_service_directory_namespace.uptime[0].namespace_id
      service_name   = google_service_directory_service.ilb[0].service_id
    }
  }

  depends_on = [
    google_service_directory_endpoint.ilb,
    google_project_iam_member.uptime_sd,
    google_compute_forwarding_rule.http,
  ]
}

resource "google_monitoring_alert_policy" "a4_uptime" {
  count = var.enable_uptime_check && var.enable_gcp_alert_policies ? 1 : 0

  display_name = "[A4][metric] ILB private uptime check failed"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Private uptime check failing"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.ilb[0].uptime_check_id}\" AND resource.type=\"servicedirectory_service\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "60s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.*"]
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = var.alert_auto_close
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}

########################################
# Cloud Scheduler 起動停止の失敗検知
########################################

# [S1] ログベースアラート: Scheduler 実行失敗
resource "google_monitoring_alert_policy" "s1_scheduler_failed_log" {
  count = local.alerts_enabled

  display_name = "[S1][log] Cloud Scheduler job failed"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "Scheduler AttemptFinished with ERROR"
    condition_matched_log {
      filter = local.scheduler_failed_filter
      label_extractors = {
        job_id = "EXTRACT(resource.labels.job_id)"
        status = "EXTRACT(jsonPayload.status)"
      }
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = var.log_alert_rate_limit
    }
    auto_close = var.alert_auto_close
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]

  documentation {
    mime_type = "text/markdown"
    content   = "Cloud Scheduler ジョブの実行が失敗しました（VM 起動/停止 API 呼び出しの失敗）。"
  }
}

# [S2] 指標アラート: ログベース指標 Scheduler 失敗数（job_id 別）
resource "google_monitoring_alert_policy" "s2_scheduler_failed_metric" {
  count = local.alerts_enabled

  display_name = "[S2][metric] Cloud Scheduler job failed (log-based metric)"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "scheduler_failed_count > 0"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.scheduler_failed.name}\" AND resource.type=\"cloud_scheduler_job\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.job_id"]
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = var.alert_auto_close
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}

# [S3] ログベースアラート: start/stop オペレーション自体の失敗（監査ログ）
resource "google_monitoring_alert_policy" "s3_compute_op_failed_log" {
  count = local.alerts_enabled

  display_name = "[S3][log] Compute instance start/stop operation failed (audit log)"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "compute.instances.start/stop ERROR"
    condition_matched_log {
      filter = local.compute_op_failed_filter
      label_extractors = {
        method   = "EXTRACT(protoPayload.methodName)"
        instance = "EXTRACT(protoPayload.resourceName)"
      }
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = var.log_alert_rate_limit
    }
    auto_close = var.alert_auto_close
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]

  documentation {
    mime_type = "text/markdown"
    content   = "Compute Engine の start/stop オペレーションが失敗しました（Scheduler の HTTP 呼び出しは成功していても VM 状態が変わっていない可能性）。"
  }
}
