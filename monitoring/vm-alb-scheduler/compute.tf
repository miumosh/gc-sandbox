resource "google_service_account" "vm" {
  account_id   = "${var.name_prefix}-vm"
  display_name = "VM runtime SA (vm-alb-scheduler)"

  depends_on = [google_project_service.this]
}

resource "google_project_iam_member" "vm" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm.email}"
}

locals {
  # 外部 IP / NAT 不要にするため、イメージ同梱の python3 で HTTP を返す
  startup_script = <<-EOT
    #!/bin/bash
    set -eu
    mkdir -p /var/www
    echo "ok from $(hostname)" > /var/www/index.html
    cat > /etc/systemd/system/simple-web.service <<'UNIT'
    [Unit]
    Description=simple web for LB health check
    After=network-online.target
    [Service]
    WorkingDirectory=/var/www
    ExecStart=/usr/bin/python3 -m http.server 80
    Restart=always
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now simple-web.service
  EOT
}

resource "google_compute_instance" "web" {
  for_each = var.instances

  name         = "${var.name_prefix}-${each.key}"
  zone         = each.value
  machine_type = var.machine_type
  tags         = ["${var.name_prefix}-web"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.app.id
    # 外部 IP なし
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    startup-script         = local.startup_script
  }

  # desired_status は指定しない（Scheduler による停止状態を Terraform が戻さないように）
  allow_stopping_for_update = true
}

# ゾーンごとの非マネージドインスタンスグループ
resource "google_compute_instance_group" "web" {
  for_each = var.instances

  name      = "${var.name_prefix}-ig-${each.key}"
  zone      = each.value
  instances = [google_compute_instance.web[each.key].self_link]

  named_port {
    name = "http"
    port = 80
  }
}

# 試験クライアント（NW 用サブネット）: 内部 VIP への疎通確認・試験トラフィック送信用
resource "google_compute_instance" "client" {
  count = var.enable_test_client ? 1 : 0

  name         = "${var.name_prefix}-client"
  zone         = values(var.instances)[0]
  machine_type = var.machine_type
  tags         = ["${var.name_prefix}-client"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.nw.id
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    # VIP へ 2 秒ごとに HTTP リクエストを送り続ける（結果は内部 ALB のリクエストログで確認）
    startup-script = var.client_traffic_enabled ? local.client_traffic_script : ""
  }

  allow_stopping_for_update = true
}

locals {
  client_traffic_script = <<-EOT
    #!/bin/bash
    cat > /etc/systemd/system/vip-traffic.service <<'UNIT'
    [Unit]
    Description=send test traffic to internal ALB VIP
    After=network-online.target
    [Service]
    ExecStart=/bin/bash -c 'while true; do curl -s -m 3 -o /dev/null -w "%%{http_code}\\n" http://${var.ilb_vip_address}/; sleep 2; done'
    Restart=always
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now vip-traffic.service
  EOT
}
