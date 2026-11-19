output "external_ip" {
  value = google_compute_instance.rhel.network_interface[0].access_config[0].nat_ip
}

output "ssh_command" {
  value = "ssh -i ${trimsuffix(var.ssh_public_key_path, ".pub")} ${var.ssh_user}@${google_compute_instance.rhel.network_interface[0].access_config[0].nat_ip}"
}
