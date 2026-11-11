# GCP ログ → Pub/Sub → Dataflow（Google 提供テンプレート Pub/Sub to Datadog）→ Datadog Logs
# Datadog API キーは Secret Manager に「手動で」バージョン追加する（state に残さない）
locals {
  lf = var.enable_log_forwarding ? 1 : 0

  # 監視に必要なログだけを転送する
  forward_filter = join(" OR ", [
    "(logName=\"projects/${var.project_id}/logs/compute.googleapis.com%2Fhealthchecks\")",
    "(resource.type=\"internal_http_lb_rule\" AND httpRequest.status>=500)",
    "(resource.type=\"cloud_scheduler_job\")",
    "(logName=\"projects/${var.project_id}/logs/cloudaudit.googleapis.com%2Factivity\" AND protoPayload.methodName=~\"compute\\.instances\\.(start|stop)$\")",
  ])
}

data "google_project" "this" {
  project_id = var.project_id
}

data "google_compute_network" "vpc" {
  name = var.network_name
}

resource "google_project_service" "lf" {
  for_each = var.enable_log_forwarding ? toset([
    "pubsub.googleapis.com",
    "dataflow.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ]) : toset([])

  service            = each.value
  disable_on_destroy = false
}

# ---- Pub/Sub ----
resource "google_pubsub_topic" "logs" {
  count = local.lf
  name  = "${var.name_prefix}-datadog-logs"

  depends_on = [google_project_service.lf]
}

resource "google_pubsub_subscription" "logs" {
  count = local.lf
  name  = "${var.name_prefix}-datadog-logs-sub"
  topic = google_pubsub_topic.logs[0].id

  ack_deadline_seconds       = 60
  message_retention_duration = "86400s"
}

resource "google_pubsub_topic" "deadletter" {
  count = local.lf
  name  = "${var.name_prefix}-datadog-logs-deadletter"

  depends_on = [google_project_service.lf]
}

resource "google_pubsub_subscription" "deadletter" {
  count = local.lf
  name  = "${var.name_prefix}-datadog-logs-deadletter-sub"
  topic = google_pubsub_topic.deadletter[0].id
}

# ---- Log sink ----
resource "google_logging_project_sink" "datadog" {
  count = local.lf

  name                   = "${var.name_prefix}-datadog-sink"
  destination            = "pubsub.googleapis.com/${google_pubsub_topic.logs[0].id}"
  filter                 = local.forward_filter
  unique_writer_identity = true
}

resource "google_pubsub_topic_iam_member" "sink_publisher" {
  count = local.lf

  topic  = google_pubsub_topic.logs[0].id
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.datadog[0].writer_identity
}

# ---- Datadog API キー（値は手動投入）----
resource "google_secret_manager_secret" "dd_api_key" {
  count = local.lf

  secret_id = "${var.name_prefix}-datadog-api-key"
  replication {
    auto {}
  }

  depends_on = [google_project_service.lf]
}

# ---- Dataflow ----
resource "google_service_account" "dataflow" {
  count = local.lf

  account_id   = "${var.name_prefix}-dd-dataflow"
  display_name = "Dataflow worker for Datadog log forwarding"
}

resource "google_project_iam_member" "dataflow_worker" {
  count = local.lf

  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${google_service_account.dataflow[0].email}"
}

resource "google_pubsub_subscription_iam_member" "dataflow" {
  for_each = var.enable_log_forwarding ? toset(["roles/pubsub.subscriber", "roles/pubsub.viewer"]) : toset([])

  subscription = google_pubsub_subscription.logs[0].id
  role         = each.value
  member       = "serviceAccount:${google_service_account.dataflow[0].email}"
}

resource "google_pubsub_topic_iam_member" "dataflow_deadletter" {
  count = local.lf

  topic  = google_pubsub_topic.deadletter[0].id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.dataflow[0].email}"
}

resource "google_secret_manager_secret_iam_member" "dataflow" {
  count = local.lf

  secret_id = google_secret_manager_secret.dd_api_key[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.dataflow[0].email}"
}

resource "google_storage_bucket" "dataflow_temp" {
  count = local.lf

  name                        = "${var.project_id}-${var.name_prefix}-dd-dataflow-tmp"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.lf]
}

resource "google_storage_bucket_iam_member" "dataflow_temp" {
  count = local.lf

  bucket = google_storage_bucket.dataflow_temp[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.dataflow[0].email}"
}

# Dataflow ワーカー用サブネット + Cloud NAT（外部 IP なしで Datadog へ送信）
resource "google_compute_subnetwork" "dataflow" {
  count = local.lf

  name                     = "${var.name_prefix}-dataflow-subnet"
  region                   = var.region
  network                  = data.google_compute_network.vpc.id
  ip_cidr_range            = var.dataflow_subnet_cidr
  private_ip_google_access = true
}

resource "google_compute_router" "dataflow" {
  count = local.lf

  name    = "${var.name_prefix}-dataflow-router"
  region  = var.region
  network = data.google_compute_network.vpc.id
}

resource "google_compute_router_nat" "dataflow" {
  count = local.lf

  name                               = "${var.name_prefix}-dataflow-nat"
  router                             = google_compute_router.dataflow[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.dataflow[0].id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# Dataflow ワーカー間通信
resource "google_compute_firewall" "dataflow" {
  count = local.lf

  name        = "${var.name_prefix}-allow-dataflow-internal"
  network     = data.google_compute_network.vpc.id
  direction   = "INGRESS"
  source_tags = ["dataflow"]
  target_tags = ["dataflow"]

  allow {
    protocol = "tcp"
    ports    = ["12345-12346"]
  }
}

resource "google_dataflow_job" "pubsub_to_datadog" {
  count = local.lf

  name                    = "${var.name_prefix}-pubsub-to-datadog"
  region                  = var.region
  template_gcs_path       = "gs://dataflow-templates-${var.region}/latest/Cloud_PubSub_to_Datadog"
  temp_gcs_location       = "${google_storage_bucket.dataflow_temp[0].url}/tmp"
  service_account_email   = google_service_account.dataflow[0].email
  subnetwork              = "regions/${var.region}/subnetworks/${google_compute_subnetwork.dataflow[0].name}"
  ip_configuration        = "WORKER_IP_PRIVATE"
  machine_type            = "n1-standard-1"
  max_workers             = 1
  enable_streaming_engine = true
  on_delete               = "cancel"

  parameters = {
    inputSubscription     = google_pubsub_subscription.logs[0].id
    url                   = "https://http-intake.logs.${var.datadog_site}"
    apiKeySource          = "SECRET_MANAGER"
    apiKeySecretId        = "${google_secret_manager_secret.dd_api_key[0].id}/versions/latest"
    outputDeadletterTopic = google_pubsub_topic.deadletter[0].id
    includePubsubMessage  = "true"
    batchCount            = "10"
  }

  depends_on = [
    google_project_iam_member.dataflow_worker,
    google_pubsub_subscription_iam_member.dataflow,
    google_pubsub_topic_iam_member.dataflow_deadletter,
    google_secret_manager_secret_iam_member.dataflow,
    google_storage_bucket_iam_member.dataflow_temp,
    google_compute_router_nat.dataflow,
  ]
}
