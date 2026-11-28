# Certificate Manager のサービスエージェントに、各下位 CA プールからの発行権限を付ける

resource "google_project_service_identity" "certmgr" {
  provider = google-beta
  service  = "certificatemanager.googleapis.com"
}

resource "google_privateca_ca_pool_iam_member" "certmgr_requester" {
  for_each = var.regions

  ca_pool = google_privateca_ca_pool.sub[each.key].id
  role    = "roles/privateca.certificateRequester"
  member  = google_project_service_identity.certmgr.member
}

resource "google_certificate_manager_certificate_issuance_config" "ic" {
  for_each = var.regions

  name     = "ic-${each.key}"
  location = each.value.region

  certificate_authority_config {
    certificate_authority_service_config {
      ca_pool = google_privateca_ca_pool.sub[each.key].id
    }
  }

  lifetime                   = var.issuance_lifetime
  rotation_window_percentage = var.rotation_window_percentage
  key_algorithm              = "RSA_2048"

  depends_on = [google_privateca_certificate_authority.sub]
}

resource "google_certificate_manager_certificate" "cert" {
  for_each = var.regions

  name     = "cert-${each.key}"
  location = each.value.region
  scope    = "DEFAULT"

  managed {
    # 共通の FQDN と、リージョン専用の名前（設計書「簡単にする工夫①」）
    domains         = [var.fqdn, each.value.regional_fqdn]
    issuance_config = google_certificate_manager_certificate_issuance_config.ic[each.key].id
  }

  depends_on = [google_privateca_ca_pool_iam_member.certmgr_requester]
}
