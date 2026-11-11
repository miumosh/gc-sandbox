resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.this]
}

# NW 用サブネット: LB フロントエンド VIP（固定プライベート IP）、試験クライアント
resource "google_compute_subnetwork" "nw" {
  name                     = "${var.name_prefix}-nw-subnet"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.nw_subnet_cidr
  private_ip_google_access = true
}

# プロキシ専用サブネット: リージョン内部 ALB（Envoy）が使用
resource "google_compute_subnetwork" "proxy_only" {
  name          = "${var.name_prefix}-proxy-only-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.proxy_only_subnet_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# アプリ用サブネット: バックエンド VM
resource "google_compute_subnetwork" "app" {
  name                     = "${var.name_prefix}-app-subnet"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.app_subnet_cidr
  private_ip_google_access = true
}

# ヘルスチェックのプローブ元 → バックエンド
resource "google_compute_firewall" "allow_lb_hc" {
  name          = "${var.name_prefix}-allow-lb-hc"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["${var.name_prefix}-web"]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

# プロキシ専用サブネット（Envoy） → バックエンド
resource "google_compute_firewall" "allow_proxy_only" {
  name          = "${var.name_prefix}-allow-proxy-only"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = [var.proxy_only_subnet_cidr]
  target_tags   = ["${var.name_prefix}-web"]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

# デバッグ用 SSH（IAP 経由のみ）
resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "${var.name_prefix}-allow-iap-ssh"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name_prefix}-web", "${var.name_prefix}-client"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
