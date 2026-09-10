# AES-256-GCM session key must be hex (openssl rand -hex 32). Alphanumeric
# random_password is rejected as "Invalid character".
resource "random_id" "session" {
  byte_length = 32
}

resource "google_secret_manager_secret" "license" {
  secret_id = "${var.name_prefix}-license"
  project   = var.project_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "license" {
  secret      = google_secret_manager_secret.license.id
  secret_data = var.agentgateway_license_key
}

resource "google_secret_manager_secret" "session" {
  secret_id = "${var.name_prefix}-session-key"
  project   = var.project_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "session" {
  secret      = google_secret_manager_secret.session.id
  secret_data = random_id.session.hex
}

resource "google_secret_manager_secret" "idp_client" {
  secret_id = "${var.name_prefix}-idp-client-secret"
  project   = var.project_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "idp_client" {
  secret      = google_secret_manager_secret.idp_client.id
  secret_data = var.idp_google_client_secret != "" ? var.idp_google_client_secret : "unset"
}
