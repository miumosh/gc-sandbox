# Datadog モニター
#   metric 系: GCP インテグレーションで取り込む指標（gcp.*）。ログ転送なしで動く
#   log 系   : log_forwarding.tf でログを Datadog に転送した場合のみ動く
locals {
  base_tags = ["env:sandbox", "service:vm-alb-scheduler", "managed-by:terraform"]
  proj      = "project_id:${var.project_id}"
  win       = var.evaluation_window # 例: last_10m
  win_short = replace(var.evaluation_window, "last_", "")

  instance_filter = join(" OR ", [for n in var.instance_names : "instance_name:${n}"])
}

########################################
# ILB 配下 VM の停止検知
########################################

# [DD-A1][log] ヘルスチェックログ UNHEALTHY 遷移（1台停止を検知）
resource "datadog_monitor" "a1_hc_unhealthy_log" {
  count = var.enable_log_forwarding ? 1 : 0

  name    = "[DD-A1][log] ILB backend UNHEALTHY (health check log)"
  type    = "log alert"
  query   = "logs(\"@data.jsonPayload.healthCheckProbeResult.healthState:UNHEALTHY @data.jsonPayload.healthCheckProbeResult.previousHealthState:HEALTHY @data.resource.labels.project_id:${var.project_id}\").index(\"*\").rollup(\"count\").last(\"${local.win_short}\") > 0"
  message = <<-EOT
    {{#is_alert}}内部 ALB のヘルスチェックでバックエンドが UNHEALTHY に遷移しました。VM 停止/アプリ停止を確認してください。{{/is_alert}}
    {{#is_recovery}}UNHEALTHY 遷移ログが収まりました。{{/is_recovery}}
    ${var.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  enable_logs_sample = true
  notify_no_data     = false
  tags               = concat(local.base_tags, ["detect:a1"])
}

# [DD-A2][log] 内部 ALB failed_to_pick_backend（全台停止）
resource "datadog_monitor" "a2_lb_no_backend_log" {
  count = var.enable_log_forwarding ? 1 : 0

  name    = "[DD-A2][log] ILB 5xx responses (request log)"
  type    = "log alert"
  query   = "logs(\"@data.resource.type:internal_http_lb_rule @data.resource.labels.forwarding_rule_name:${var.forwarding_rule_name} @data.httpRequest.status:>=500\").index(\"*\").rollup(\"count\").last(\"${local.win_short}\") > 0"
  message = <<-EOT
    {{#is_alert}}内部 ALB が正常なバックエンドを選べず 5xx を返しました（全台停止の可能性）。{{/is_alert}}
    ${var.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  enable_logs_sample = true
  notify_no_data     = false
  tags               = concat(local.base_tags, ["detect:a2"])
}

# [DD-A3][metric] GCP ログベース指標 UNHEALTHY 遷移数
resource "datadog_monitor" "a3_hc_unhealthy_metric" {
  name    = "[DD-A3][metric] ILB backend UNHEALTHY (GCP log-based metric)"
  type    = "query alert"
  query   = "sum(${local.win}):sum:gcp.logging.user.${var.hc_unhealthy_metric}{${local.proj}}.as_count() > 0"
  message = <<-EOT
    {{#is_alert}}内部 ALB のバックエンドが UNHEALTHY に遷移しました（GCP ログベース指標）。{{/is_alert}}
    ${var.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  require_full_window = false
  notify_no_data      = false
  tags                = concat(local.base_tags, ["detect:a3"])
}

# [DD-A4][metric] GCP プライベート Uptime Check（全台停止）
resource "datadog_monitor" "a4_uptime" {
  count = var.uptime_check_id == null ? 0 : 1

  name    = "[DD-A4][metric] ILB private uptime check failed"
  type    = "query alert"
  query   = "max(last_5m):max:gcp.monitoring.uptime_check.check_passed{${local.proj},check_id:${var.uptime_check_id}} < 1"
  message = <<-EOT
    {{#is_alert}}内部 VIP へのプライベート Uptime Check が全リージョンで失敗しています。{{/is_alert}}
    ${var.notify}
  EOT

  monitor_thresholds {
    critical = 1
  }

  require_full_window = false
  notify_no_data      = true
  no_data_timeframe   = 15
  tags                = concat(local.base_tags, ["detect:a4"])
}

# [DD-A5][metric] VM の uptime 指標が途絶（ALB に依らない VM 停止検知・参考）
resource "datadog_monitor" "a5_vm_uptime_nodata" {
  name    = "[DD-A5][metric] VM stopped (gcp.gce.instance.uptime no data)"
  type    = "query alert"
  query   = "avg(${local.win}):avg:gcp.gce.instance.uptime{${local.proj},(${local.instance_filter})} by {instance_name} < 0"
  message = <<-EOT
    {{#is_no_data}}VM {{instance_name.name}} の uptime 指標が途絶えました（停止の可能性）。{{/is_no_data}}
    ${var.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  notify_no_data      = true
  no_data_timeframe   = 20
  require_full_window = false
  tags                = concat(local.base_tags, ["detect:a5"])
}

# [DD-A6][metric] 内部 ALB 5xx 応答数（全台停止・参考）
resource "datadog_monitor" "a6_lb_5xx_metric" {
  name    = "[DD-A6][metric] ILB 5xx responses"
  type    = "query alert"
  query   = "sum(${local.win}):sum:gcp.loadbalancing.https.internal.request_count{${local.proj},forwarding_rule_name:${var.forwarding_rule_name},response_code_class:500}.as_count() > 0"
  message = <<-EOT
    {{#is_alert}}内部 ALB が 5xx を返しています。{{/is_alert}}
    ${var.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  require_full_window = false
  notify_no_data      = false
  tags                = concat(local.base_tags, ["detect:a6"])
}

# [DD-A7][metric] 内部 ALB のバックエンド（IG）別リクエスト数の途絶（GCP 側 A6 相当。ALB 視点で VM 停止を検知）
#   前提: 常時トラフィックがあること
resource "datadog_monitor" "a7_backend_requests_nodata" {
  name    = "[DD-A7][metric] ILB backend receives no requests"
  type    = "query alert"
  query   = "sum(${local.win}):sum:gcp.loadbalancing.https.internal.backend_request_count{${local.proj},forwarding_rule_name:${var.forwarding_rule_name}} by {backend_name}.as_count() < 0"
  message = <<-EOT
    {{#is_no_data}}内部 ALB のバックエンド {{backend_name.name}} へのリクエストが途絶えました（VM 停止の可能性）。{{/is_no_data}}
    ${var.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  notify_no_data      = true
  no_data_timeframe   = 20
  require_full_window = false
  tags                = concat(local.base_tags, ["detect:a7"])
}

########################################
# Cloud Scheduler 起動停止の失敗検知
########################################

# [DD-S1][log] Scheduler 実行失敗ログ
resource "datadog_monitor" "s1_scheduler_failed_log" {
  count = var.enable_log_forwarding ? 1 : 0

  name    = "[DD-S1][log] Cloud Scheduler job failed"
  type    = "log alert"
  query   = "logs(\"@data.resource.type:cloud_scheduler_job @data.severity:ERROR @data.resource.labels.project_id:${var.project_id}\").index(\"*\").rollup(\"count\").last(\"${local.win_short}\") > 0"
  message = <<-EOT
    {{#is_alert}}Cloud Scheduler ジョブ（VM 起動/停止）の実行が失敗しました。{{/is_alert}}
    ${var.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  enable_logs_sample = true
  notify_no_data     = false
  tags               = concat(local.base_tags, ["detect:s1"])
}

# [DD-S2][metric] GCP ログベース指標 Scheduler 失敗数（job_id 別）
resource "datadog_monitor" "s2_scheduler_failed_metric" {
  name    = "[DD-S2][metric] Cloud Scheduler job failed (GCP log-based metric)"
  type    = "query alert"
  query   = "sum(${local.win}):sum:gcp.logging.user.${var.scheduler_failed_metric}{${local.proj}} by {job_id}.as_count() > 0"
  message = <<-EOT
    {{#is_alert}}Cloud Scheduler ジョブ {{job_id.name}} が失敗しました。{{/is_alert}}
    ${var.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  require_full_window = false
  notify_no_data      = false
  tags                = concat(local.base_tags, ["detect:s2"])
}

# [DD-S3][log] Compute start/stop オペレーション失敗（監査ログ）
resource "datadog_monitor" "s3_compute_op_failed_log" {
  count = var.enable_log_forwarding ? 1 : 0

  name    = "[DD-S3][log] Compute start/stop operation failed (audit log)"
  type    = "log alert"
  query   = "logs(\"@data.protoPayload.methodName:(v1.compute.instances.start OR v1.compute.instances.stop) @data.severity:ERROR @data.resource.labels.project_id:${var.project_id}\").index(\"*\").rollup(\"count\").last(\"${local.win_short}\") > 0"
  message = <<-EOT
    {{#is_alert}}Compute Engine の start/stop オペレーションが失敗しました。{{/is_alert}}
    ${var.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  enable_logs_sample = true
  notify_no_data     = false
  tags               = concat(local.base_tags, ["detect:s3"])
}

# [DD-S3m][metric] GCP ログベース指標 Compute オペレーション失敗数
resource "datadog_monitor" "s3m_compute_op_failed_metric" {
  name    = "[DD-S3m][metric] Compute start/stop operation failed (GCP log-based metric)"
  type    = "query alert"
  query   = "sum(${local.win}):sum:gcp.logging.user.${var.compute_op_failed_metric}{${local.proj}}.as_count() > 0"
  message = <<-EOT
    {{#is_alert}}Compute Engine の start/stop オペレーションが失敗しました（GCP ログベース指標）。{{/is_alert}}
    ${var.notify}
  EOT

  monitor_thresholds {
    critical = 0
  }

  require_full_window = false
  notify_no_data      = false
  tags                = concat(local.base_tags, ["detect:s3m"])
}
