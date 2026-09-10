output "hostname" {
  description = "Public lab hostname."
  value       = var.hostname
}

output "whoami_url" {
  description = "Public /whoami URL through the HTTPS load balancer."
  value       = "https://${var.hostname}/whoami"
}

output "load_balancer_ip" {
  description = "Regional external IPv4 of the HTTPS forwarding rule."
  value       = google_compute_address.lb.address
}

output "mig_name" {
  description = "Regional managed instance group name."
  value       = google_compute_region_instance_group_manager.agw.name
}

output "config_bucket" {
  description = "GCS bucket that holds the file baseline."
  value       = google_storage_bucket.config.name
}

output "sql_instance" {
  description = "Cloud SQL instance name (not the database URL)."
  value       = google_sql_database_instance.agw.name
}

output "redis_host" {
  description = "Memorystore Redis private IP (not a secret)."
  value       = google_redis_instance.ratelimit.host
}

output "idp_issuer" {
  description = "Identity Platform JWT issuer URL."
  value       = local.idp_issuer
}

output "idp_jwks_url" {
  description = "Identity Platform JWKS URL."
  value       = local.idp_jwks_url
}

output "ui_redirect_uri" {
  description = "OIDC redirect that must be registered on the UI confidential client."
  value       = "https://${var.hostname}/oauth/callback"
}

output "secret_ids" {
  description = "Secret Manager secret ids (names only — never values)."
  value = {
    license           = google_secret_manager_secret.license.secret_id
    session_key       = google_secret_manager_secret.session.secret_id
    database_url      = google_secret_manager_secret.database_url.secret_id
    idp_client_secret = google_secret_manager_secret.idp_client.secret_id
  }
}
