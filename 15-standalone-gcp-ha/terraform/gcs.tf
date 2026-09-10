resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "google_storage_bucket" "config" {
  name                        = "${var.name_prefix}-config-${random_id.bucket_suffix.hex}"
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  force_destroy               = true

  versioning {
    enabled = true
  }

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_object" "config" {
  name   = "config.yaml"
  bucket = google_storage_bucket.config.name
  source = "${path.module}/../config/config.yaml"
}

resource "google_storage_bucket_object" "model_costs" {
  name   = "model-costs.json"
  bucket = google_storage_bucket.config.name
  source = "${path.module}/../config/model-costs.json"
}

resource "google_storage_bucket_object" "ratelimit" {
  name   = "ratelimit.yaml"
  bucket = google_storage_bucket.config.name
  source = "${path.module}/../config/ratelimit.yaml"
}

resource "google_storage_bucket_iam_member" "vm_reader" {
  bucket = google_storage_bucket.config.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.vm.email}"
}
