resource "google_compute_network" "main" {
  name                    = "vpc-main"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  for_each = var.regions

  name                     = "snet-${each.key}"
  region                   = each.value.region
  network                  = google_compute_network.main.id
  ip_cidr_range            = each.value.subnet_cidr
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "proxy_only" {
  for_each = var.regions

  name          = "snet-proxy-${each.key}"
  region        = each.value.region
  network       = google_compute_network.main.id
  ip_cidr_range = each.value.proxy_only_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# 業務サーバへ：ヘルスチェック範囲とプロキシ専用サブネットから tcp:80
resource "google_compute_firewall" "allow_hc_proxy" {
  name    = "drtest-allow-hc-proxy"
  network = google_compute_network.main.id
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  source_ranges = concat(
    ["35.191.0.0/16", "130.211.0.0/22"],
    [for r in var.regions : r.proxy_only_cidr],
  )
  target_tags = ["drtest-web"]
}

# IAP 経由の SSH（クライアント VM・業務サーバの操作用）
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "drtest-allow-iap-ssh"
  network = google_compute_network.main.id
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
}

# 外部 IP なしの VM がパッケージを入れるための Cloud NAT
resource "google_compute_router" "nat" {
  for_each = var.regions

  name    = "drtest-router-${each.key}"
  region  = each.value.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "nat" {
  for_each = var.regions

  name                               = "drtest-nat-${each.key}"
  region                             = each.value.region
  router                             = google_compute_router.nat[each.key].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
