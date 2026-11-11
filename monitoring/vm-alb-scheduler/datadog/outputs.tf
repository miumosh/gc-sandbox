output "monitor_ids" {
  value = {
    a1  = try(datadog_monitor.a1_hc_unhealthy_log[0].id, null)
    a2  = try(datadog_monitor.a2_lb_no_backend_log[0].id, null)
    a3  = datadog_monitor.a3_hc_unhealthy_metric.id
    a4  = try(datadog_monitor.a4_uptime[0].id, null)
    a5  = datadog_monitor.a5_vm_uptime_nodata.id
    a6  = datadog_monitor.a6_lb_5xx_metric.id
    a7  = datadog_monitor.a7_backend_requests_nodata.id
    s1  = try(datadog_monitor.s1_scheduler_failed_log[0].id, null)
    s2  = datadog_monitor.s2_scheduler_failed_metric.id
    s3  = try(datadog_monitor.s3_compute_op_failed_log[0].id, null)
    s3m = datadog_monitor.s3m_compute_op_failed_metric.id
  }
}

output "dd_api_key_secret" {
  description = "ログ転送有効時: このシークレットに Datadog API キーを手動で追加する"
  value       = try(google_secret_manager_secret.dd_api_key[0].id, null)
}
