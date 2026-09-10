resource "google_compute_address" "lb" {
  name         = "${var.name_prefix}-lb"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  depends_on = [google_project_service.apis]
}

resource "google_compute_region_health_check" "ready" {
  name   = "${var.name_prefix}-ready"
  region = var.region

  timeout_sec         = 5
  check_interval_sec  = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = var.readiness_port
    request_path = "/readyz"
  }
}

resource "google_compute_region_backend_service" "agw" {
  name                  = var.name_prefix
  region                = var.region
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 60
  health_checks         = [google_compute_region_health_check.ready.id]
  locality_lb_policy    = "ROUND_ROBIN"

  backend {
    group           = google_compute_region_instance_group_manager.agw.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = 1
  }

  depends_on = [google_compute_subnetwork.proxy]
}

resource "google_compute_region_url_map" "agw" {
  name            = var.name_prefix
  region          = var.region
  default_service = google_compute_region_backend_service.agw.id
}

resource "google_certificate_manager_certificate" "agw" {
  name     = var.name_prefix
  location = var.region
  project  = var.project_id

  managed {
    domains            = [var.hostname]
    dns_authorizations = [google_certificate_manager_dns_authorization.agw.id]
  }

  # Regional managed certs require a same-region DNS authorization and a
  # published challenge record before issuance can start.
  depends_on = [
    google_project_service.apis,
    google_dns_record_set.cert_authorization,
  ]
}

resource "google_compute_region_target_https_proxy" "agw" {
  name                             = var.name_prefix
  region                           = var.region
  url_map                          = google_compute_region_url_map.agw.id
  certificate_manager_certificates = [google_certificate_manager_certificate.agw.id]
}

resource "google_compute_forwarding_rule" "https" {
  name                  = "${var.name_prefix}-https"
  region                = var.region
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  ip_address            = google_compute_address.lb.address
  target                = google_compute_region_target_https_proxy.agw.id
  network               = google_compute_network.vpc.id
  network_tier          = "PREMIUM"

  depends_on = [google_compute_subnetwork.proxy]
}
