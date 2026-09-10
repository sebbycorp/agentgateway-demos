data "google_dns_managed_zone" "public" {
  name    = var.dns_managed_zone
  project = var.project_id
}

resource "google_dns_record_set" "agw" {
  name         = "${var.hostname}."
  type         = "A"
  ttl          = 60
  managed_zone = data.google_dns_managed_zone.public.name
  rrdatas      = [google_compute_address.lb.address]
  project      = var.project_id
}

# Regional Google-managed certificates cannot use load-balancer authorization.
# They require a same-region PER_PROJECT_RECORD DNS authorization plus the
# CNAME that Certificate Manager publishes on dns_resource_record.
resource "google_certificate_manager_dns_authorization" "agw" {
  name     = "${var.name_prefix}-dnsauth"
  location = var.region
  project  = var.project_id
  domain   = var.hostname
  type     = "PER_PROJECT_RECORD"

  depends_on = [google_project_service.apis]
}

resource "google_dns_record_set" "cert_authorization" {
  name         = google_certificate_manager_dns_authorization.agw.dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.agw.dns_resource_record[0].type
  ttl          = 60
  managed_zone = data.google_dns_managed_zone.public.name
  rrdatas      = [google_certificate_manager_dns_authorization.agw.dns_resource_record[0].data]
  project      = var.project_id
}
