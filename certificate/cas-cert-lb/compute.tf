# 業務サーバ：リージョンごとに MIG（サイズ 2）。python3 http.server でリージョン名を返す

resource "google_compute_instance_template" "web" {
  for_each = var.regions

  name_prefix  = "drtest-web-${each.key}-"
  machine_type = "e2-micro"
  region       = each.value.region
  tags         = ["drtest-web"]

  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
    disk_size_gb = 10
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main[each.key].id
  }

  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      mkdir -p /srv/www
      echo "region=${each.key} host=$(hostname)" > /srv/www/index.html
      cd /srv/www && nohup python3 -m http.server 80 >/var/log/http.log 2>&1 &
    EOT
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_instance_group_manager" "web" {
  for_each = var.regions

  name               = "drtest-mig-${each.key}"
  region             = each.value.region
  base_instance_name = "drtest-web-${each.key}"
  target_size        = var.backend_size

  version {
    instance_template = google_compute_instance_template.web[each.key].id
  }

  named_port {
    name = "http"
    port = 80
  }
}

# 検証用クライアント VM（外部 IP なし）。ルート CA 証明書を /tmp/root.pem に置く
resource "google_compute_instance" "client" {
  for_each = var.regions

  name         = "drtest-client-${each.key == "tokyo" ? "tk" : "os"}"
  machine_type = "e2-micro"
  zone         = each.value.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main[each.key].id
  }

  metadata = {
    root-pem       = google_privateca_certificate_authority.root.pem_ca_certificates[0]
    ssh-keys       = var.client_ssh_public_key
    startup-script = <<-EOT
      #!/bin/bash
      curl -s -H 'Metadata-Flavor: Google' \
        http://metadata.google.internal/computeMetadata/v1/instance/attributes/root-pem > /tmp/root.pem
      chmod 644 /tmp/root.pem
      command -v dig >/dev/null || (apt-get update -q && apt-get install -yq dnsutils)
    EOT
  }

  depends_on = [google_compute_router_nat.nat]
}
