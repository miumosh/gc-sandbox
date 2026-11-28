# リージョン内部 ALB（東京・大阪で 1 セットずつ）

resource "google_compute_region_health_check" "web" {
  for_each = var.regions

  name   = "drtest-hc-${each.key}"
  region = each.value.region
  http_health_check {
    port_specification = "USE_NAMED_PORT"
    port_name          = "http"
    request_path       = "/"
  }
  check_interval_sec = 5
  timeout_sec        = 5
}

resource "google_compute_region_backend_service" "web" {
  for_each = var.regions

  name                  = "drtest-bs-${each.key}"
  region                = each.value.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http"
  health_checks         = [google_compute_region_health_check.web[each.key].id]

  backend {
    group           = google_compute_region_instance_group_manager.web[each.key].instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

resource "google_compute_region_url_map" "web" {
  for_each = var.regions

  name            = "um-${each.key}"
  region          = each.value.region
  default_service = google_compute_region_backend_service.web[each.key].id
}

resource "google_compute_region_target_https_proxy" "web" {
  for_each = var.regions

  name    = "proxy-${each.key}"
  region  = each.value.region
  url_map = google_compute_region_url_map.web[each.key].id
  # 証明書マップは使わず、同じリージョンの証明書を直接設定する
  certificate_manager_certificates = [google_certificate_manager_certificate.cert[each.key].id]
}

resource "google_compute_address" "vip" {
  for_each = var.regions

  name         = "drtest-vip-${each.key}"
  region       = each.value.region
  subnetwork   = google_compute_subnetwork.main[each.key].id
  address_type = "INTERNAL"
  address      = each.value.vip
}

resource "google_compute_forwarding_rule" "web" {
  for_each = var.regions

  name                  = "fr-${each.key}"
  region                = each.value.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  network               = google_compute_network.main.id
  subnetwork            = google_compute_subnetwork.main[each.key].id
  ip_address            = google_compute_address.vip[each.key].id
  ip_protocol           = "TCP"
  port_range            = "443"
  target                = google_compute_region_target_https_proxy.web[each.key].id
  allow_global_access   = true

  depends_on = [google_compute_subnetwork.proxy_only]
}
