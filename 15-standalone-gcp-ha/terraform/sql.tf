resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_database_instance" "agw" {
  name             = "${var.name_prefix}-pg"
  database_version = "POSTGRES_16"
  region           = var.region
  project          = var.project_id

  settings {
    # POSTGRES_16 defaults to ENTERPRISE_PLUS when edition is unset, which
    # rejects custom tiers. ENTERPRISE + db-custom-1-3840 is the lab SKU.
    edition           = "ENTERPRISE"
    tier              = "db-custom-1-3840"
    availability_type = "ZONAL"
    disk_size         = 10
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc.id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled = false
    }
  }

  deletion_protection = false

  depends_on = [google_service_networking_connection.psa]
}

resource "google_sql_database" "agw" {
  name     = "agw"
  instance = google_sql_database_instance.agw.name
}

resource "google_sql_user" "agw" {
  name     = "agw"
  instance = google_sql_database_instance.agw.name
  password = random_password.db.result
}

resource "google_secret_manager_secret" "database_url" {
  secret_id = "${var.name_prefix}-database-url"
  project   = var.project_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "database_url" {
  secret = google_secret_manager_secret.database_url.id
  secret_data = format(
    "postgresql://agw:%s@%s:5432/agw",
    random_password.db.result,
    google_sql_database_instance.agw.private_ip_address,
  )
}
