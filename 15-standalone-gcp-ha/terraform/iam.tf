resource "google_service_account" "vm" {
  account_id   = var.name_prefix
  display_name = "agentgateway GCP HA VM"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "vm" {
  for_each = toset([
    "roles/secretmanager.secretAccessor",
    "roles/storage.objectViewer",
    "roles/aiplatform.user",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_member" "vm_oslogin" {
  project = var.project_id
  role    = "roles/compute.osLogin"
  member  = "serviceAccount:${google_service_account.vm.email}"
}
