resource "google_dns_managed_zone" "sample" {
  name        = "zone-sample"
  dns_name    = var.dns_zone_name
  visibility  = "private"
  description = "internal zone (drtest)"
  private_visibility_config {
    networks {
      network_url = google_compute_network.main.id
    }
  }
}

locals {
  ilb = {
    for k, r in var.regions : k => {
      load_balancer_type = "regionalL7ilb"
      ip_address         = r.vip
      port               = "443"
      ip_protocol        = "tcp"
      network_url        = google_compute_network.main.id
      project            = var.project_id
      region             = r.region
    }
  }
}

# test.sample.com：フェイルオーバー（プライマリ東京、バックアップ大阪）、TTL 30 秒
# T09/T10 では gcloud（設計書のコマンド）で切り替えるため、ここは通常時の状態を定義する
resource "google_dns_record_set" "fqdn" {
  managed_zone = google_dns_managed_zone.sample.name
  name         = "${var.fqdn}."
  type         = "A"
  ttl          = 30

  routing_policy {
    primary_backup {
      trickle_ratio = 0
      primary {
        internal_load_balancers {
          load_balancer_type = local.ilb.tokyo.load_balancer_type
          ip_address         = local.ilb.tokyo.ip_address
          port               = local.ilb.tokyo.port
          ip_protocol        = local.ilb.tokyo.ip_protocol
          network_url        = local.ilb.tokyo.network_url
          project            = local.ilb.tokyo.project
          region             = local.ilb.tokyo.region
        }
      }
      backup_geo {
        location = var.regions.osaka.region
        health_checked_targets {
          internal_load_balancers {
            load_balancer_type = local.ilb.osaka.load_balancer_type
            ip_address         = local.ilb.osaka.ip_address
            port               = local.ilb.osaka.port
            ip_protocol        = local.ilb.osaka.ip_protocol
            network_url        = local.ilb.osaka.network_url
            project            = local.ilb.osaka.project
            region             = local.ilb.osaka.region
          }
        }
      }
    }
  }

  depends_on = [google_compute_forwarding_rule.web]
}

# リージョン専用の名前（通常の A レコード）
resource "google_dns_record_set" "regional" {
  for_each = var.regions

  managed_zone = google_dns_managed_zone.sample.name
  name         = "${each.value.regional_fqdn}."
  type         = "A"
  ttl          = 300
  rrdatas      = [each.value.vip]
}

# T15：受信サーバーポリシー（オンプレ接続はないため、受信 IP ができることだけ確認する）
resource "google_dns_policy" "inbound" {
  name                      = "drtest-inbound"
  enable_inbound_forwarding = true
  networks {
    network_url = google_compute_network.main.id
  }
}
