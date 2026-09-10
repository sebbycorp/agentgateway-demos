variable "project_id" {
  description = "GCP project that hosts the lab."
  type        = string
  default     = "maniak-io"
}

variable "region" {
  description = "GCP region for the regional MIG, LB, SQL, and Memorystore."
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "Zones the regional MIG balances across."
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b", "us-central1-c"]
}

variable "hostname" {
  description = "Public hostname for the HTTPS load balancer and UI OIDC redirect."
  type        = string
  default     = "agw-gcp-ha.maniak.io"
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone DNS name (trailing dot) that contains hostname."
  type        = string
  default     = "maniak.io."
}

variable "dns_managed_zone" {
  description = "Cloud DNS managed zone resource name (not the DNS name)."
  type        = string
  default     = "maniak"
}

variable "agentgateway_license_key" {
  description = "Solo Enterprise license. Supply only via TF_VAR_agentgateway_license_key. Never commit or output."
  type        = string
  sensitive   = true
}

variable "agentgateway_image" {
  description = "Pinned Solo Enterprise container image. Bump the tag here; do not use :latest."
  type        = string
  default     = "cr.agentgateway.dev/agentgateway:2026.9.0"
}

variable "data_port" {
  description = "Gateway data-plane port behind the HTTPS load balancer."
  type        = number
  default     = 3000
}

variable "readiness_port" {
  description = "agentgateway readiness listener used for MIG auto-heal and LB health."
  type        = number
  default     = 15021
}

variable "admin_port" {
  description = "Admin API bind on loopback inside each VM."
  type        = number
  default     = 15000
}

variable "ratelimit_port" {
  description = "Local Envoy ratelimit gRPC port on each VM."
  type        = number
  default     = 8081
}

variable "machine_type" {
  description = "GCE machine type for each MIG instance."
  type        = string
  default     = "e2-standard-2"
}

variable "vpc_cidr" {
  description = "Primary subnet CIDR for private VMs."
  type        = string
  default     = "10.10.0.0/20"
}

variable "proxy_cidr" {
  description = "Proxy-only subnet CIDR required by the regional external Application LB."
  type        = string
  default     = "10.20.0.0/23"
}

variable "psa_cidr" {
  description = "Allocated range for Private Service Access (Cloud SQL)."
  type        = string
  default     = "10.30.0.0/16"
}

variable "idp_ui_client_id" {
  description = "OIDC confidential client id for the admin UI. Empty until the console client exists."
  type        = string
  default     = ""
}

variable "idp_google_client_id" {
  description = "Optional Google OAuth client id for Identity Platform Google IdP. Leave empty to skip the IdP resource (console appendix)."
  type        = string
  default     = ""
}

variable "idp_google_client_secret" {
  description = "Optional Google OAuth client secret for Identity Platform. Supply via TF_VAR only."
  type        = string
  default     = ""
  sensitive   = true
}

variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
  default     = "agw-gcp-ha"
}
