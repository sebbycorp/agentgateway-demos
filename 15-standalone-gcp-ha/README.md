# 15 — Standalone Enterprise HA on GCE

Three private GCE VMs in a **regional managed instance group**, each running **Solo Enterprise for agentgateway** as a Docker container. A regional HTTPS load balancer fronts the data port. Config is a versioned GCS object; Cloud SQL Postgres holds the request log and the hybrid overlay; Memorystore Redis backs fleet-wide `remoteRateLimit`. Identity is Google Identity Platform. Vertex AI uses the VM service account (ADC).

This is a three-node standalone HA fleet on GCP. There is no Kubernetes.

Docs: [install](https://docs.solo.io/agentgateway/standalone/latest/setup/install/), [GCP / Vertex](https://docs.solo.io/agentgateway/standalone/latest/integrations/cloud-providers/gcp/), [storage](https://docs.solo.io/agentgateway/standalone/latest/setup/storage/), [database](https://docs.solo.io/agentgateway/standalone/latest/setup/database/), [rate limits](https://docs.solo.io/agentgateway/standalone/latest/configuration/resiliency/rate-limits/).

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
# or
export AGENTGATEWAY_LICENSE_KEY
```

Terraform writes it to Secret Manager (`sensitive = true`). There is no Terraform output of the raw key. `.gitignore` blocks `.env`, `*.auto.tfvars`, `secrets*.tfvars`, and tfstate.

## Defaults

| Knob | Value |
| --- | --- |
| Project | `maniak-io` |
| Region | `us-central1` |
| Hostname | `agw-gcp-ha.maniak.academy` |
| Image | `cr.agentgateway.dev/agentgateway:2026.9.0` (from Solo GCP docs; bump `TF_VAR_agentgateway_image`) |

Do not use `:latest`. To bump the image, set `TF_VAR_agentgateway_image` and roll the MIG.

## What Terraform creates

- VPC, private subnet, **proxy-only subnet** (regional external Application LB), Cloud NAT, IAP/LB firewalls
- VM service account: `secretmanager.secretAccessor`, `storage.objectViewer`, `aiplatform.user`, logging/monitoring write
- Secret Manager: license, session key, database URL, IdP client secret
- Versioned GCS bucket + `config.yaml` / `model-costs.json` / `ratelimit.yaml`
- Cloud SQL Postgres 16 (private IP via Private Service Access)
- Memorystore Redis STANDARD_HA
- Regional MIG size 3, Debian 12 + Docker startup, auto-heal on `/readyz`
- Regional HTTPS LB, Certificate Manager cert, Cloud DNS A record
- Identity Platform project config (email sign-in). Google IdP + UI confidential client: see appendix

## Apply (do not run in CI without a license env)

```bash
cd 15-standalone-gcp-ha
export LAB_GCP_PROJECT=maniak-io
export TF_VAR_agentgateway_license_key   # your shell; never commit
./scripts/00-preflight.sh    # no spend; does not print the license
./scripts/01-apply.sh
./scripts/02-verify.sh
./scripts/10-routing.sh
# optional: AGW_ID_TOKEN=... ./scripts/11-auth.sh
./scripts/teardown.sh
```

Preflight prints a rough **few USD/hour** estimate. Tear down when done.

## Config cookbook

Baseline is `config/config.yaml`. Env placeholders only (`$SESSION_KEY`, `$AGW_DATABASE_URL`, `$IDP_ISSUER`, `$RATELIMIT_HOST`, …).

- **Startup-only:** listen addresses, session key, database URL, storage mode
- **Live reload:** gateways, routes, llm, mcp, ui — push to GCS, nodes sync within a minute
- **Hybrid overlay:** admin API/UI writes to Cloud SQL; siblings converge

`/whoami` is an in-process `directResponse` used by HA scripts.

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

Terraform enables Identity Platform (`google_identity_platform_config`) and, if you pass `TF_VAR_idp_google_client_id` / `TF_VAR_idp_google_client_secret`, the Google IdP.

The **UI confidential OAuth client** with redirect `https://agw-gcp-ha.maniak.academy/oauth/callback` is created in Cloud Console → APIs & Services → Credentials → OAuth client (Web). Then set `TF_VAR_idp_ui_client_id` and the client secret via `TF_VAR_idp_google_client_secret` (or update the Secret Manager secret) and refresh the MIG.

JWT issuer used in config: `https://securetoken.google.com/<project>`. JWKS is Google’s published securetoken key set. Scripts accept `AGW_ID_TOKEN` from your shell and never print it.

## Memorystore SKU

Default is Redis 7 STANDARD_HA (`google_redis_instance`). If the region only offers Valkey, change `memorystore.tf` to the Memorystore Valkey resource and keep port 6379 for the ratelimit sidecar.
