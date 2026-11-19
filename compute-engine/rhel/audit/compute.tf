resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_instance" "rhel" {
  name         = "${var.name_prefix}-vm"
  zone         = var.zone
  machine_type = var.machine_type
  tags         = ["${var.name_prefix}-vm"]

  boot_disk {
    initialize_params {
      image = var.image
      size  = 20 # RHEL イメージの最小サイズ
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this.id
    access_config {} # エフェメラル外部 IP（SSH はファイアウォールで自宅 IP のみ許可）
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  # サービスアカウントなし（検証に GCP API は不要）
  metadata = {
    # OS Login を使わず、metadata の鍵でログインする（プロジェクト共通鍵はブロック）
    enable-oslogin         = "FALSE"
    block-project-ssh-keys = "TRUE"
    ssh-keys               = "${var.ssh_user}:${trimspace(file(pathexpand(var.ssh_public_key_path)))}"
  }

  # 監査ルールは手順で手動配置する（startup-script では変更しない）
  allow_stopping_for_update = true
}
