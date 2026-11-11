output "ilb_vip" {
  description = "内部 ALB のフロントエンド VIP"
  value       = google_compute_address.ilb_vip.address
}

output "instances" {
  value = { for k, v in google_compute_instance.web : k => { name = v.name, zone = v.zone } }
}

output "test_client" {
  value = var.enable_test_client ? { name = google_compute_instance.client[0].name, zone = google_compute_instance.client[0].zone } : null
}

output "scheduler_jobs" {
  value = concat(
    [for j in google_cloud_scheduler_job.vm : j.name],
    [for j in google_cloud_scheduler_job.failure_test : j.name],
  )
}

# datadog/ 側に渡す値
output "datadog_inputs" {
  description = "datadog/ の terraform.tfvars に転記する値"
  value = {
    project_id               = var.project_id
    network_name             = google_compute_network.vpc.name
    forwarding_rule_name     = google_compute_forwarding_rule.http.name
    instance_names           = [for v in google_compute_instance.web : v.name]
    hc_unhealthy_metric      = google_logging_metric.hc_unhealthy.name
    scheduler_failed_metric  = google_logging_metric.scheduler_failed.name
    compute_op_failed_metric = google_logging_metric.compute_op_failed.name
    uptime_check_id          = var.enable_uptime_check ? google_monitoring_uptime_check_config.ilb[0].uptime_check_id : null
  }
}

output "log_filters" {
  description = "Logs Explorer で動作確認するためのフィルタ"
  value = {
    a1_a3_hc_unhealthy   = local.hc_unhealthy_filter
    a2_lb_5xx            = local.lb_no_backend_filter
    a7_vm_stopped        = local.vm_stopped_filter
    s1_s2_scheduler_fail = local.scheduler_failed_filter
    s3_compute_op_failed = local.compute_op_failed_filter
  }
}
