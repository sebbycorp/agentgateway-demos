# Agentgateway Enterprise GCP HA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver `15-standalone-gcp-ha/` in sebbycorp/agentgateway-demos: Terraform + scripts + README how-to with screenshots running Solo Enterprise agentgateway as Docker on a 3-node GCE regional MIG (GCS, Cloud SQL hybrid, Memorystore, Google Identity Platform, Vertex ADC).

**Architecture:** 3 private GCE VMs in regional MIG behind regional HTTPS LB; Docker enterprise image each; GCS file baseline; Cloud SQL Postgres request log + hybrid overlay; Memorystore Redis remote rate limits; secrets/license via env → Secret Manager only; Identity Platform JWT+UI OIDC; Vertex via VM SA ADC.

**Tech Stack:** Terraform ≥1.5, google provider, GCE MIG+Docker, GCS, Cloud SQL, Memorystore, Secret Manager, Cloud DNS+managed certs, Identity Platform, bash/jq/curl scripts, cr.agentgateway.dev enterprise image.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-10-agentgateway-gcp-ha-design.md`
- NEVER commit license; `TF_VAR_agentgateway_license_key` / `AGENTGATEWAY_LICENSE_KEY` → Secret Manager; `sensitive = true`; no outputs of raw key; gitignore secrets tfvars and `.env`
- NEVER mention third-party cookbook hostnames; cite only `https://docs.solo.io/agentgateway/standalone/latest/`
- project `maniak-io`; region `us-central1`; hostname `agw-gcp-ha.maniak.academy`
- no public VM IPs; no public SSH; IAP+OS Login
- pin concrete image tag; no `:latest`
- out of v1: multi-region, WAF deep-dive, full Model Armor, dual IdP, K8s

## File map

```text
15-standalone-gcp-ha/
  README.md
  .gitignore
  .env.example
  docs/screenshots/.gitkeep
  config/config.yaml
  config/model-costs.json
  config/ratelimit.yaml
  terraform/{versions,providers,variables,outputs,network,mig,lb,gcs,sql,memorystore,secrets,iam,dns,identity}.tf
  terraform/templates/startup.sh.tftpl
  scripts/{lib,00-preflight,01-apply,02-verify,10-routing,11-auth,12-llm,13-mcp,15-ratelimit,20-ha-node-loss,21-ha-mcp-session,22-ha-config-push,23-ha-ui-overlay,teardown}.sh
```

---

### Task 1: Scaffold + gitignore secrets

**Files:**
- Create: `15-standalone-gcp-ha/.gitignore`
- Create: `15-standalone-gcp-ha/.env.example`
- Create: `15-standalone-gcp-ha/README.md` (license warning)
- Create: `15-standalone-gcp-ha/scripts/lib.sh`

- [x] **Step 1: Gitignore**

```
.env
*.auto.tfvars
secrets*.tfvars
.terraform/
*.tfstate
*.tfstate.*
```

- [x] **Step 2: `lib.sh` with `die` / `ok` / `require_env` / `lab_project` / `lab_region`**

- [x] **Step 3: Commit** (`feat(15): scaffold GCP HA lab + secret gitignore`)

---

### Task 2: Terraform vars/providers + Secret Manager license

**Files:** `terraform/versions.tf`, `providers.tf`, `variables.tf`, `outputs.tf`, `secrets.tf`

**Interfaces:**
- Consumes: `TF_VAR_agentgateway_license_key` (string, sensitive)
- Produces: secrets `agw-gcp-ha-license`, `agw-gcp-ha-session-key`, `agw-gcp-ha-idp-client-secret`

```hcl
variable "agentgateway_license_key" {
  type      = string
  sensitive = true
}
```

Never `output` the raw key. `.env.example` lists names only.

- [x] **Step 1: Write vars + secrets**
- [x] **Step 2: Commit**

---

### Task 3: network.tf + iam.tf

VPC, private subnet, proxy-only subnet, Cloud NAT, firewall (LB health + IAP SSH, deny public SSH at priority 65534). SA `agw-gcp-ha` with `secretmanager.secretAccessor`, `storage.objectViewer`, `aiplatform.user`, logging/monitoring.

- [x] **Step 1: Write network + IAM**
- [x] **Step 2: `terraform validate`**
- [x] **Step 3: Commit**

---

### Task 4: gcs + sql + memorystore + baseline config.yaml

Versioned bucket; Cloud SQL private Postgres URL in Secret Manager; Memorystore Redis STANDARD_HA; config with hybrid storage, `$AGW_DATABASE_URL`, `$SESSION_KEY`, `/whoami`, Vertex stub, `$RATELIMIT_HOST`.

- [x] **Step 1: Write resources + config**
- [x] **Step 2: Commit**

---

### Task 5: mig + startup + lb + dns

Docker run pinned image, `--env-file` (license from secret files, never logged). Regional MIG size 3, auto-heal on `/readyz`. Regional HTTPS LB + Certificate Manager + Cloud DNS.

```bash
docker run -d --name agw --network host \
  --env-file /etc/agentgateway/agw.env \
  -v /etc/agentgateway:/config \
  "$IMAGE" -f /config/config.yaml
```

- [x] **Step 1: Write MIG/LB/DNS/startup**
- [x] **Step 2: Commit**

---

### Task 6: identity.tf

`google_identity_platform_config` + optional Google IdP. Redirect `https://agw-gcp-ha.maniak.academy/oauth/callback`. Console appendix for the confidential web client.

- [x] **Step 1: Write identity + README appendix**
- [x] **Step 2: Commit**

---

### Task 7: all scripts

preflight (license non-empty, value not printed) → apply → verify → feature +/- → HA → teardown.

- [x] **Step 1: Write scripts**
- [x] **Step 2: `chmod +x` + `bash -n`**
- [x] **Step 3: Commit**

---

### Task 8: apply + screenshots + full README

Live `maniak-io` apply is **out of band** for the code PR (no apply in the agent task). Screenshots stay empty (`.gitkeep`). README how-to is in-repo.

- [ ] **Step 1: Apply only with a human-held license env**
- [ ] **Step 2: Capture screenshots without secret values**
- [ ] **Step 3: Teardown unless asked to keep**

---

### Task 9: PR hygiene

Search the branch for the banned third-party cookbook hostname and for license/JWT payloads (compact JWS-looking strings). FAIL if either hits. Update the follow-up PR. Do not put those search terms into committed docs as examples.

- [x] **Step 1: Scan**
- [x] **Step 2: Open follow-up PR**

---

## Spec coverage

| Design section | Task |
| --- | --- |
| Goal / 3-node standalone HA | 1–7 |
| License secrecy | 1, 2, 7, 9 |
| AWS→GCP twin table | README + terraform modules |
| Network / MIG / LB / DNS / cert | 3, 5 |
| GCS / Cloud SQL / Memorystore / SM / IAM | 2, 3, 4 |
| Identity Platform | 6 |
| Startup vs live / hybrid | 4, 5, config.yaml |
| Demo features 1–8 | config.yaml + scripts 10–15 |
| HA drills | scripts 20–23 |
| Scripts contract / teardown / cost | 7, README |
| Non-goals (no K8s, no dual IdP, no WAF) | omitted from v1 |

## Open implement-time confirmations

| Item | Default in this PR | Confirm at apply time |
| --- | --- | --- |
| Image tag | `cr.agentgateway.dev/agentgateway:2026.9.0` (Solo GCP install example) | Pull from Solo registry; pin digest if the tag moved |
| Identity Platform TF | `google_identity_platform_config` + optional Google IdP | Create UI confidential client in console if TF cannot |
| Memorystore SKU | Redis 7 `STANDARD_HA` `DIRECT_PEERING` | Switch to Valkey resource if Redis is unavailable in `us-central1` |
| Cloud SQL private | Private Service Access (`google_service_networking_connection`) | Use PSC only if PSA is blocked in the project |

## Sample blocks (no real secrets)

**gitignore:** `*.auto.tfvars`, `secrets*.tfvars`, `.env`, `.terraform/`, `*.tfstate*`

**sensitive variable:**

```hcl
variable "agentgateway_license_key" {
  type      = string
  sensitive = true
}
```

**secret resource:** `google_secret_manager_secret` + `google_secret_manager_secret_version` with `secret_data = var.agentgateway_license_key` (never output).

**docker run:** `--env-file /etc/agentgateway/agw.env` + `-v /etc/agentgateway:/config` + pinned image. Do not pass the license on `docker run -e` from a shell history file.
