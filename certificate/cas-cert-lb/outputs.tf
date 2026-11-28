output "root_ca_name" {
  value = google_privateca_certificate_authority.root.name
}

output "sub_ca_names" {
  value = { for k, v in google_privateca_certificate_authority.sub : k => v.name }
}

output "certificate_ids" {
  value = { for k, v in google_certificate_manager_certificate.cert : k => v.id }
}

output "vips" {
  value = { for k, v in google_compute_forwarding_rule.web : k => v.ip_address }
}

output "client_vms" {
  value = { for k, v in google_compute_instance.client : k => "${v.name} (${v.zone})" }
}
