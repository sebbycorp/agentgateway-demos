locals {
  idp_issuer   = "https://securetoken.google.com/${var.project_id}"
  idp_jwks_url = "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"
}

# Enables Identity Toolkit / Identity Platform for the project.
# A confidential OAuth web client for https://<hostname>/oauth/callback is
# created in the Cloud Console (APIs & Services → Credentials) if this
# provider cannot represent it. See README appendix.
resource "google_identity_platform_config" "default" {
  project = var.project_id

  sign_in {
    allow_duplicate_emails = false

    email {
      enabled           = true
      password_required = true
    }

    anonymous {
      enabled = false
    }
  }

  authorized_domains = [
    var.hostname,
    "${var.project_id}.firebaseapp.com",
    "${var.project_id}.web.app",
  ]

  depends_on = [google_project_service.apis]
}

resource "google_identity_platform_default_supported_idp_config" "google" {
  count = var.idp_google_client_id != "" ? 1 : 0

  project       = var.project_id
  enabled       = true
  idp_id        = "google.com"
  client_id     = var.idp_google_client_id
  client_secret = var.idp_google_client_secret

  depends_on = [google_identity_platform_config.default]
}
