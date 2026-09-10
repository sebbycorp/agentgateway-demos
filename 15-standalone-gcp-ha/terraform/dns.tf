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
