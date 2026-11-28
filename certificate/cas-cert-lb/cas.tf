# ルート CA は東京に 1 つ。下位 CA は東京・大阪に 1 つずつ（発行元はどちらも東京の root-pool）

resource "google_privateca_ca_pool" "root" {
  name     = "root-pool"
  location = var.regions.tokyo.region
  tier     = var.ca_tier
  publishing_options {
    publish_ca_cert = true
    publish_crl     = false
  }
}

resource "google_privateca_certificate_authority" "root" {
  pool                     = google_privateca_ca_pool.root.name
  certificate_authority_id = "root-ca"
  location                 = var.regions.tokyo.region
  type                     = "SELF_SIGNED"
  lifetime                 = "315360000s" # 10 年

  config {
    subject_config {
      subject {
        common_name  = "Sample Root CA"
        organization = "Sample"
      }
    }
    x509_config {
      ca_options {
        is_ca = true
      }
      key_usage {
        base_key_usage {
          cert_sign = true
          crl_sign  = true
        }
        extended_key_usage {}
      }
    }
  }

  key_spec {
    algorithm = "EC_P384_SHA384"
  }

  # 検証用：destroy で即時削除する（既定は 30 日の猶予期間）
  deletion_protection                    = false
  skip_grace_period                      = true
  ignore_active_certificates_on_deletion = true
}

resource "google_privateca_ca_pool" "sub" {
  for_each = var.regions

  name     = "sub-pool-${each.key}"
  location = each.value.region
  tier     = var.ca_tier
  publishing_options {
    publish_ca_cert = true
    publish_crl     = false
  }
}

resource "google_privateca_certificate_authority" "sub" {
  for_each = var.regions

  pool                     = google_privateca_ca_pool.sub[each.key].name
  certificate_authority_id = "sub-ca-${each.key}"
  location                 = each.value.region
  type                     = "SUBORDINATE"
  lifetime                 = "157680000s" # 5 年

  # 大阪の下位 CA も、東京のルート CA を発行元にする（リージョンをまたぐ指定）
  subordinate_config {
    certificate_authority = google_privateca_certificate_authority.root.name
  }

  config {
    subject_config {
      subject {
        common_name  = "Sample Sub CA ${title(each.key)}"
        organization = "Sample"
      }
    }
    x509_config {
      ca_options {
        is_ca                  = true
        max_issuer_path_length = 0
      }
      key_usage {
        base_key_usage {
          cert_sign = true
          crl_sign  = true
        }
        extended_key_usage {}
      }
    }
  }

  key_spec {
    algorithm = "EC_P256_SHA256"
  }

  deletion_protection                    = false
  skip_grace_period                      = true
  ignore_active_certificates_on_deletion = true
}
