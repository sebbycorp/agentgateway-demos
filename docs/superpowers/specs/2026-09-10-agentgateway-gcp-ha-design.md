# Design: Agentgateway Enterprise standalone — 3-node HA on GCE

**Date:** 2026-09-10  
**Repo:** `sebbycorp/agentgateway-demos`  
**Folder:** `15-standalone-gcp-ha/`  
**Status:** Draft for review  

## Goal

Ship a Terraform lab + how-to guide (with screenshots) that runs **Solo Enterprise for agentgateway** as a **standalone container** on a **3-node GCE regional MIG**, modeled on the AWS HA cookbook at [mastertheagent.com/solo/agentgateway-standalone-aws-ha](https://mastertheagent.com/solo/agentgateway-standalone-aws-ha/) and Solo’s standalone docs ([install](https://docs.solo.io/agentgateway/standalone/latest/setup/install/), [GCP](https://docs.solo.io/agentgateway/standalone/latest/integrations/cloud-providers/gcp/)).

Success means: `terraform apply` (plus thin scripts) brings up a fleet that proves routing, Google Identity auth, Vertex via ADC, MCP, fleet-wide rate limits, hybrid config storage, and the same class of HA drills as the AWS guide — without Kubernetes.

## Non-goals (v1)

- Multi-region active-active
- Deep WAF cookbook
- Full Model Armor / every guardrail vendor
- Dual IdP (Entra + Google)
- Kubernetes / Helm / control-plane mode

## Hard constraint: license secrecy

- Enterprise license is required (`lt: ent`).
- **Never** commit the license to git, Terraform source, screenshots, README examples, CI logs, or design/plan docs.
- Supply only via environment: `TF_VAR_agentgateway_license_key` or `AGENTGATEWAY_LICENSE_KEY`.
- Terraform writes it into **GCP Secret Manager** as a sensitive value; VMs pull at boot into the container env.
- `.gitignore` must exclude `*.auto.tfvars`, `secrets*.tfvars`, `.env`, and any local secret files.
- Mark the Terraform variable `sensitive = true`; do not `output` the raw key.
- Prefer remote state with encryption; treat state as secret-bearing.

## Architecture (AWS → GCP twin)

| AWS HA guide | This lab |
| --- | --- |
| 3 EC2 + ASG across AZs | 3 GCE VMs in a regional MIG (balanced across zones) |
| systemd binary | Docker on each VM — enterprise image from Solo registry |
| ALB → :3000 + readiness | Regional external HTTPS LB → data port; health on readiness |
| S3 + sync timer | GCS versioned bucket + sync/reload on each node |
| Aurora Postgres | Cloud SQL Postgres — request log + `storage.mode: hybrid` |
| ElastiCache Valkey | Memorystore Redis — `remoteRateLimit` |
| Secrets Manager | Secret Manager — license, session key, DB URL, IdP client secret |
| Cognito | Google Identity Platform — JWT + UI OIDC |
| Bedrock via instance role | Vertex AI via VM service account (ADC) |
| SSM, no SSH | IAP + OS Login; no public SSH / no public VM IPs |

```text
                    Internet
                        |
              Regional HTTPS LB
               (managed cert)
                        |
        +---------------+---------------+---------------+
        |               |               |
     VM / zone A     VM / zone B     VM / zone C
     Docker AGW      Docker AGW      Docker AGW
        |               |               |
        +-------+-------+-------+-------+
                |               |
           Cloud SQL      Memorystore
           (Postgres)      (Redis)
                |
              GCS config (versioned)
```

## Target environment

- **GCP project:** `maniak-io` (assumed; override via tfvars)
- **Region:** `us-central1`
- **Hostname:** `agw-gcp-ha.maniak.academy` (Cloud DNS + Google-managed cert)
- **VMs:** private IPs only; Cloud NAT for egress; IAP for admin
- **Image:** Solo Enterprise container (`cr.agentgateway.dev/...` — pin a specific tag in Terraform variables; document how to bump)

## Repo layout

```text
15-standalone-gcp-ha/
  README.md                 # how-to guide (screenshots linked/embedded)
  docs/screenshots/         # console + CLI proof shots
  terraform/                # root module
  config/config.yaml        # file baseline (no secrets)
  scripts/
    00-preflight.sh
    01-apply.sh
    02-verify.sh
    10-routing.sh … 15-ratelimit.sh
    20-ha-*.sh
    teardown.sh
```

Also add this design under `docs/superpowers/specs/2026-09-10-agentgateway-gcp-ha-design.md`.

## Terraform surfaces (logical modules)

1. **Network** — VPC, private subnets, Cloud NAT, firewall (LB → data/readiness; IAP → SSH alternate; deny public SSH)
2. **MIG** — instance template (Docker + startup), regional MIG size 3, auto-healing on readiness failure
3. **Load balancing** — regional external HTTPS, backend service to instance group, Google-managed cert for hostname
4. **GCS** — versioned config bucket; IAM for VM SA read
5. **Cloud SQL** — Postgres, private IP preferred; schema created by agentgateway on first start
6. **Memorystore** — Redis for rate-limit counters
7. **Secret Manager** — license, session key, DB URL, IdP secrets; VM SA accessor
8. **IAM** — VM SA: `secretmanager.secretAccessor`, GCS objectViewer, `aiplatform.user`, logging/monitoring write
9. **Identity Platform** — OIDC app / API for JWT issuer + JWKS; UI confidential client; redirect `https://agw-gcp-ha.maniak.academy/oauth/callback`
10. **DNS** — record for hostname under `maniak.academy` pointing at the LB

Exact resource types can flex during implementation as long as the twin mapping and security constraints hold.

## Startup vs live config

Mirror the AWS guide:

- **Startup-only** (`config` block): listen addresses, session key, database URL, storage mode, logging/tracing basics — rolling MIG refresh to change
- **Live reload:** gateways, routes, policies, llm, mcp, ui; GCS push → node sync → file watcher reload
- **Hybrid overlay:** admin UI / admin API writes to Cloud SQL; fanout so siblings converge; new MIG instances inherit overlay

## Demo features (v1)

1. Routing + `/whoami` (node + zone)
2. Google Identity JWT + CEL authorization
3. Vertex via ADC (VM SA); optional second provider behind env-injected key in Secret Manager
4. Virtual keys; regex guardrails (Model Armor optional follow-up)
5. MCP federation + per-tool authorization
6. `localRateLimit` vs `remoteRateLimit` (Memorystore)
7. Admin UI on data plane behind Identity Platform OIDC
8. Hybrid storage: GCS baseline + Cloud SQL overlay

## HA drills

| Drill | Expect |
| --- | --- |
| Terminate / delete one MIG instance | Replacement healthy; same binary/config hash |
| One MCP session → all three private backends | Shared `session.key` makes sessions portable |
| GCS `config.yaml` push | Fleet converges without restart; streaming not dropped |
| Create overlay resource on one node | Visible on siblings via Cloud SQL; survives creator node loss |

## Scripts contract

Same spirit as the AWS lab: preflight (no spend) → apply → verify → feature scripts with positive+negative cases → HA scripts → teardown that sweeps leftovers. Exit non-zero on assertion failure.

## How-to / screenshots

README sections: architecture, what Terraform creates, apply walkthrough, config cookbook (snippets), HA proofs, ops (IAP shell, config_dump), teardown, cost note.

Screenshots (console): MIG instances by zone, LB backend health, Cloud SQL, Memorystore, Secret Manager (names only — never secret values), Identity Platform app, Vertex traffic / whoami distribution.

## Cost & teardown

- Expected while up: on the order of a few USD/hour (3 VMs + Cloud SQL + Memorystore + LB + NAT). Preflight prints a rough estimate.
- `scripts/teardown.sh` destroys the stack and sweeps common leftovers.
- Tear down when done.

## Implementation order (after plan approval)

1. Scaffold `15-standalone-gcp-ha/` + this design in specs
2. Terraform network → MIG+Docker → LB+DNS+cert
3. Cloud SQL + Memorystore + Secret Manager wiring
4. Identity Platform + config.yaml baseline
5. Scripts verify + feature + HA
6. Apply in `maniak-io`, capture screenshots, finish README
7. PR to `sebbycorp/agentgateway-demos`

## Open points (non-blocking)

- Exact enterprise image tag/digest to pin (confirm against Solo registry at implement time)
- Whether Memorystore uses Redis or Valkey SKU available in region
- Private Service Connect vs private services access for Cloud SQL

## References

- https://mastertheagent.com/solo/agentgateway-standalone-aws-ha/
- https://docs.solo.io/agentgateway/standalone/latest/setup/install/
- https://docs.solo.io/agentgateway/standalone/latest/integrations/cloud-providers/gcp/
- https://docs.solo.io/agentgateway/standalone/latest/integrations/
- https://docs.solo.io/agentgateway/standalone/latest/documentation/
