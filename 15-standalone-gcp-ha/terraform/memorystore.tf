resource "google_redis_instance" "ratelimit" {
  name               = "${var.name_prefix}-redis"
  tier               = "STANDARD_HA"
  memory_size_gb     = 1
  region             = var.region
  project            = var.project_id
  redis_version      = "REDIS_7_0"
  authorized_network = google_compute_network.vpc.id
  connect_mode       = "DIRECT_PEERING"
  display_name       = "agw-gcp-ha remote rate limit counters"

  depends_on = [google_project_service.apis]
}
