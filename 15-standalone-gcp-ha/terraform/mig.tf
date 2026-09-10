data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"
}

resource "google_compute_instance_template" "agw" {
  name_prefix  = "${var.name_prefix}-"
  project      = var.project_id
  machine_type = var.machine_type

  disk {
    source_image = data.google_compute_image.debian.self_link
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
    disk_type    = "pd-balanced"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    # No access_config → no public IP. Egress is Cloud NAT.
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = templatefile("${path.module}/templates/startup.sh.tftpl", {
      project_id          = var.project_id
      region              = var.region
      config_bucket       = google_storage_bucket.config.name
      image               = var.agentgateway_image
      ratelimit_image     = var.ratelimit_image
      license_secret      = google_secret_manager_secret.license.secret_id
      session_secret      = google_secret_manager_secret.session.secret_id
      database_url_secret = google_secret_manager_secret.database_url.secret_id
      idp_secret          = google_secret_manager_secret.idp_client.secret_id
      redis_host          = google_redis_instance.ratelimit.host
      redis_port          = google_redis_instance.ratelimit.port
      hostname            = var.hostname
      data_port           = var.data_port
      readiness_port      = var.readiness_port
      admin_port          = var.admin_port
      ratelimit_port      = var.ratelimit_port
      idp_issuer          = local.idp_issuer
      idp_jwks_url        = local.idp_jwks_url
      idp_ui_client_id    = var.idp_ui_client_id
      vertex_project      = var.project_id
      vertex_region       = var.region
    })
  }

  tags = [var.name_prefix]

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_health_check" "mig_ready" {
  name = "${var.name_prefix}-mig-ready"

  timeout_sec         = 5
  check_interval_sec  = 10
  healthy_threshold   = 2
  unhealthy_threshold = 5

  http_health_check {
    port         = var.readiness_port
    request_path = var.readiness_path
  }
}

resource "google_compute_region_instance_group_manager" "agw" {
  name               = var.name_prefix
  region             = var.region
  base_instance_name = var.name_prefix
  target_size        = 3

  version {
    instance_template = google_compute_instance_template.agw.id
  }

  named_port {
    name = "http"
    port = var.data_port
  }

  distribution_policy_zones        = var.zones
  distribution_policy_target_shape = "EVEN"

  auto_healing_policies {
    health_check      = google_compute_health_check.mig_ready.id
    initial_delay_sec = 300
  }

  update_policy {
    type                           = "PROACTIVE"
    minimal_action                 = "REPLACE"
    most_disruptive_allowed_action = "REPLACE"
    max_surge_fixed                = 3
    max_unavailable_fixed          = 0
    instance_redistribution_type   = "PROACTIVE"
    replacement_method             = "SUBSTITUTE"
  }

  depends_on = [
    google_storage_bucket_object.config,
    google_secret_manager_secret_version.license,
    google_secret_manager_secret_version.database_url,
  ]
}
