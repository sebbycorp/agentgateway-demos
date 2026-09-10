# 15 — Standalone Enterprise HA on GCE

Three private GCE VMs in a **regional managed instance group**, each running **Solo Enterprise for agentgateway** as a Docker container. A regional HTTPS load balancer fronts the data port. Config is a versioned GCS object; Cloud SQL Postgres holds the request log and the hybrid overlay; Memorystore Redis backs fleet-wide `remoteRateLimit`. Identity is Google Identity Platform. Vertex AI uses the VM service account (ADC).

This is a three-node standalone HA fleet on GCP. There is no Kubernetes.

Docs: [install](https://docs.solo.io/agentgateway/standalone/latest/setup/install/), [license](https://docs.solo.io/agentgateway/standalone/latest/setup/license/), [GCP / Vertex](https://docs.solo.io/agentgateway/standalone/latest/integrations/cloud-providers/gcp/), [storage](https://docs.solo.io/agentgateway/standalone/latest/setup/storage/), [database](https://docs.solo.io/agentgateway/standalone/latest/setup/database/), [API keys](https://docs.solo.io/agentgateway/standalone/latest/configuration/security/apikey-authn/), [rate limits](https://docs.solo.io/agentgateway/standalone/latest/configuration/resiliency/rate-limits/), [changelog](https://docs.solo.io/agentgateway/standalone/latest/reference/changelog/changelog/).

## Architecture (AWS twin → this lab)

| Typical 3-node AWS HA pattern | This lab |
| --- | --- |
| 3 EC2 + ASG across AZs | 3 GCE VMs in a regional MIG |
| systemd binary | Docker on each VM |
| ALB → data + readiness | Regional external HTTPS LB + managed cert |
| S3 + sync | Versioned GCS bucket + cron sync |
| Aurora Postgres | Cloud SQL Postgres (`storage.mode: hybrid`) |
| ElastiCache | Memorystore Redis + local ratelimit sidecar |
| Secrets Manager | Secret Manager |
| Cognito | Identity Platform JWT + UI OIDC |
| Bedrock instance role | Vertex via VM SA ADC |
| SSM, no SSH | IAP + OS Login; no public VM IPs |

## License (never in git)

Enterprise (`lt: ent`) is required. **Do not commit the license.** Repo users must not see it.

```bash
export TF_VAR_agentgateway_license_key  # set in your shell only
# or (Enterprise container env name)
export ENTERPRISE_AGENTGATEWAY_LICENSE_KEY
```

The proxy reads `ENTERPRISE_AGENTGATEWAY_LICENSE_KEY` ([licensing](https://docs.solo.io/agentgateway/standalone/latest/setup/license/)). Terraform still consumes `TF_VAR_agentgateway_license_key` and writes Secret Manager; startup copies that value into the container env.

Terraform writes it to Secret Manager (`sensitive = true`). There is no Terraform output of the raw key. `.gitignore` blocks `.env`, `*.auto.tfvars`, `secrets*.tfvars`, and tfstate.

## Defaults

| Knob | Value |
| --- | --- |
| Project | `maniak-io` |
| Region | `us-central1` |
| Hostname | `agw-gcp-ha.maniak.io` |
| Cloud DNS zone | `maniak` (`maniak.io.`) |
| Image | `us-docker.pkg.dev/solo-public/enterprise-agentgateway/agentgateway-enterprise:2026.8.2` ([changelog](https://docs.solo.io/agentgateway/standalone/latest/reference/changelog/changelog/); bump `TF_VAR_agentgateway_image`) |
| Ratelimit image | `envoyproxy/ratelimit:v1.4.0` (`TF_VAR_ratelimit_image`) |
| Readiness | `15021` `/healthz/ready` |

Do not use `:latest`. To bump the image, set `TF_VAR_agentgateway_image` and roll the MIG.

## What Terraform creates

- VPC, private subnet, **proxy-only subnet** (regional external Application LB), Cloud NAT, IAP/LB firewalls
- VM service account: `secretmanager.secretAccessor`, `storage.objectViewer`, `aiplatform.user`, logging/monitoring write
- Secret Manager: license, session key, database URL, IdP client secret
- Versioned GCS bucket + `config.yaml` / `model-costs.json` / `ratelimit.yaml`
- Cloud SQL Postgres 16 `ENTERPRISE` + `db-custom-1-3840` (private IP via Private Service Access)
- Memorystore Redis STANDARD_HA
- Regional MIG size 3, Debian 12 + Docker startup, auto-heal on `/healthz/ready`
- Regional HTTPS LB, Certificate Manager regional managed cert (DNS authorization + Cloud DNS CNAME), Cloud DNS A record
- Identity Platform project config (email sign-in). Google IdP + UI confidential client: see appendix

## Apply (do not run in CI without a license env)

User ADC credentials must send a quota/billing project. The providers set `user_project_override` and `billing_project` so Identity Toolkit (`google_identity_platform_config`) is not charged to the Cloud SDK OAuth client. Also pin ADC itself:

```bash
gcloud auth application-default login
gcloud auth application-default set-quota-project maniak-io
gcloud services enable identitytoolkit.googleapis.com --project=maniak-io
```

Terraform enables `identitytoolkit.googleapis.com` during apply; enabling it first avoids a 403 if ADC still lacks a quota project.

```bash
cd 15-standalone-gcp-ha
export LAB_GCP_PROJECT=maniak-io
export TF_VAR_agentgateway_license_key   # or ENTERPRISE_AGENTGATEWAY_LICENSE_KEY; never commit
./scripts/00-preflight.sh    # no spend; does not print the license
./scripts/01-apply.sh
./scripts/02-verify.sh
./scripts/10-routing.sh
# optional: AGW_ID_TOKEN=... ./scripts/11-auth.sh
./scripts/teardown.sh
```

Preflight prints a rough **few USD/hour** estimate. Tear down when done.

## Config cookbook

Baseline is `config/config.yaml`. Env placeholders only (`$SESSION_KEY`, `$AGW_DATABASE_URL`, `$IDP_ISSUER`, `$RATELIMIT_HOST`, …). `/whoami` is the HA probe (`directResponse`). `llm` / `mcp` / `ui` are included so later scripts have something to hit; expand virtual keys and UI OIDC after the fleet is up.

- **Startup-only:** listen addresses, session key, database URL, storage mode
- **Live reload:** gateways, routes, llm, mcp, ui — push to GCS, nodes sync within a minute
- **Hybrid overlay:** admin API/UI writes to Cloud SQL; siblings converge
- **`SESSION_KEY`:** 32-byte hex (`random_id` byte_length=32 → `.hex`). Alphanumeric passwords fail with "Invalid character".
- **`AGW_NODE_ID`:** GCE **instance name** (quoted string). Numeric instance id breaks YAML/header fields.
- **`llm.policies.apiKey.keys`:** required on 2026.8.2 ([API key auth](https://docs.solo.io/agentgateway/standalone/latest/configuration/security/apikey-authn/), [config resources](https://docs.solo.io/agentgateway/standalone/latest/operations/config-resources/)). Baseline uses `keys: []`; add keys via admin API or GCS next — do not commit real keys.
- **Config file perms:** enterprise container is non-root; startup `chmod 0644`s `config.yaml`, `model-costs.json`, and the ratelimit config after each GCS sync.

## Ops

```bash
# IAP shell (no public SSH)
gcloud compute ssh INSTANCE --tunnel-through-iap --project=maniak-io --zone=ZONE

# config dump on a node (admin is loopback)
curl -s http://127.0.0.1:15000/config_dump | jq .
```

## Screenshots

Put console proof shots in `docs/screenshots/`. Never capture Secret Manager **values**, license text, or tokens. Names only.

## Appendix: Identity Platform console gap

Terraform enables Identity Platform (`google_identity_platform_config`) and, if you pass `TF_VAR_idp_google_client_id` / `TF_VAR_idp_google_client_secret`, the Google IdP. Identity Toolkit API (`identitytoolkit.googleapis.com`) must be enabled in the lab project. User ADC needs `gcloud auth application-default set-quota-project` for that project — a quota_project_id in the ADC file alone is not enough unless the provider sends `x-goog-user-project` (`user_project_override` + `billing_project`).

The **UI confidential OAuth client** with redirect `https://agw-gcp-ha.maniak.io/oauth/callback` is created in Cloud Console → APIs & Services → Credentials → OAuth client (Web). Then set `TF_VAR_idp_ui_client_id` and the client secret via `TF_VAR_idp_google_client_secret` (or update the Secret Manager secret) and refresh the MIG.

JWT issuer used in config: `https://securetoken.google.com/<project>`. JWKS is Google’s published securetoken key set. Scripts accept `AGW_ID_TOKEN` from your shell and never print it.

## Memorystore SKU

Default is Redis 7 STANDARD_HA (`google_redis_instance`). If the region only offers Valkey, change `memorystore.tf` to the Memorystore Valkey resource and keep port 6379 for the ratelimit sidecar.
