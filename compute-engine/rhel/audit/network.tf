# 専用 VPC（default VPC には 0.0.0.0/0 の SSH 許可ルールがあるため使わない）
resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.name_prefix}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr
}

# 自宅のグローバル IP からの SSH のみ許可（ほかの受信は VPC の暗黙の deny で拒否）
resource "google_compute_firewall" "allow_ssh_from_home" {
  name          = "${var.name_prefix}-allow-ssh-from-home"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = [var.allowed_ssh_cidr]
  target_tags   = ["${var.name_prefix}-vm"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
