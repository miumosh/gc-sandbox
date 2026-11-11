# リージョン内部アプリケーションロードバランサ（HTTP, INTERNAL_MANAGED）

# フロントエンド VIP: NW 用サブネットの固定プライベート IP
resource "google_compute_address" "ilb_vip" {
  name         = "${var.name_prefix}-ilb-vip"
  region       = var.region
  subnetwork   = google_compute_subnetwork.nw.id
  address_type = "INTERNAL"
  address      = var.ilb_vip_address
}

resource "google_compute_region_health_check" "http" {
  name                = "${var.name_prefix}-hc"
  region              = var.region
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2

  http_health_check {
    port         = 80
    request_path = "/"
  }

  # ヘルス状態の遷移（HEALTHY <-> UNHEALTHY）をログに出す
  log_config {
    enable = true
  }

  depends_on = [google_project_service.this]
}

resource "google_compute_region_backend_service" "web" {
  name                  = "${var.name_prefix}-bes"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  health_checks         = [google_compute_region_health_check.http.id]

  dynamic "backend" {
    for_each = google_compute_instance_group.web
    content {
      group           = backend.value.self_link
      balancing_mode  = "UTILIZATION"
      capacity_scaler = 1.0
    }
  }

  # リクエストログ（全件）
  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_region_url_map" "web" {
  name            = "${var.name_prefix}-urlmap"
  region          = var.region
  default_service = google_compute_region_backend_service.web.id
}

resource "google_compute_region_target_http_proxy" "web" {
  name    = "${var.name_prefix}-http-proxy"
  region  = var.region
  url_map = google_compute_region_url_map.web.id
}

resource "google_compute_forwarding_rule" "http" {
  name                  = "${var.name_prefix}-fr-http"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  ip_protocol           = "TCP"
  port_range            = "80"
  network               = google_compute_network.vpc.id
  subnetwork            = google_compute_subnetwork.nw.id
  ip_address            = google_compute_address.ilb_vip.id
  target                = google_compute_region_target_http_proxy.web.id
  network_tier          = "PREMIUM"

  # プライベート Uptime Check のチェッカーは他リージョン扱いになるため、グローバルアクセスを許可する
  allow_global_access = var.enable_uptime_check

  # プロキシ専用サブネットが先に存在している必要がある
  depends_on = [google_compute_subnetwork.proxy_only]
}
