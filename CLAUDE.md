# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of self-contained **AgentGateway** demos and workshops. AgentGateway (https://agentgateway.dev) is an open-source proxy for LLM and MCP traffic. Each numbered top-level directory is an independent demo with its own scripts, config, and readme — there is no shared build system, package manifest, or test runner across the repo. Work inside one demo directory at a time.

## Deployment modes

Demos use one of these ways to run AgentGateway. Identify which a demo uses before editing.

1. **Kubernetes** (`01`, `03`, `04`, `05`, `06`, `07`, `09`, `17-codex-kind`) — A local `kind` cluster + Helm install of the AgentGateway control plane, configured via Gateway API resources. The LLM/MCP provider is a custom `AgentgatewayBackend` CRD (`agentgateway.dev/v1alpha1`); traffic is routed to it with a standard `HTTPRoute` whose `backendRefs` point at the backend with `group: agentgateway.dev, kind: AgentgatewayBackend`. API keys are stored in Kubernetes `Secret`s.

2. **Standalone** (`00`, `08`, `07/standalone`, `16`, `18`) — The `agentgateway` binary (or Docker image) run directly against a `config.yaml`: `agentgateway -f config.yaml`. The standalone config schema is different from the K8s CRDs — it nests `binds → listeners → routes → backends` (or the newer `gateways` / `llm` shape). Proxy listener is `:3000` or `:4000`, admin UI is `http://localhost:15000/ui/`. Validate config against `# yaml-language-server: $schema=https://agentgateway.dev/schema/config`.

3. **Standalone image in-cluster** (`17-k8s-api-key-scoped-token-budgets`) — Kind-friendly `kubectl apply -f` manifests only (no `setup.sh` / `deploy.sh` / `run.sh`). Runs `cr.agentgateway.dev/agentgateway:v1.5.0` as a Deployment because API-key-scoped budgets (`llm.policies.apiKey.keys[].budgets`) are standalone-only in v1.5.0 and are not an `AgentgatewayPolicy` CRD.

## Per-demo conventions

K8s demos share a consistent script set — match it when adding a demo (`17-k8s-api-key-scoped-token-budgets` is the exception: apply-only YAML + how-to README, no helper scripts):

- `deploy.sh` — preflight-checks tools (`kind`, `kubectl`, `helm`, `jq`) and required API-key env vars, creates the kind cluster (idempotent: skips if it exists), installs Gateway API CRDs + AgentGateway Helm charts, then applies Gateway/Backend/HTTPRoute resources.
- `test.sh` — port-forwards `svc/agentgateway-proxy` and sends `curl` requests to verify routing/behavior.
- `cleanup.sh` — deletes resources and the kind cluster.
- `step-by-step.sh` — annotated walkthrough version of the deploy (echoes each command as it runs); used for live demos.
- `readme.md` / `README.md` — architecture diagram, key concepts, quick start, manual steps.

Each deploy script pins its own versions and **its own cluster name** (clusters do not collide, so demos can run simultaneously):

| Demo | Cluster name | AGW version |
|------|--------------|-------------|
| 01-installagentgateway | `agw-install` | v1.1.0 |
| 03-loadbalancing-models | `agw-loadbalancing` | v1.0.1 |
| 04-vitural-keys | `agw-virtual-keys` | v1.1.0 |
| 05-content-based | `agw-content-based` | v1.1.0 |
| 06-virtual-mcp | `agw-series-demo` | v1.1.0 |
| 09-k8s-langfuse | `agw-k8s-langfuse` | v1.1.0 |
| 07-bedrock-llm/oss | `agw-bedrock` | v1.1.0 |
| 07-bedrock-llm/enterprise | `agw-bedrock-ent` | v2026.6.3 (ent) + Solo UI 0.5.0 |
| 103-agw-tokenomics-with-f5-tool-modes | `agw-f5-tool-modes` | v2026.6.1 |
| 104-ent-github-tokenomics | `agw-github-tokenomics` | v2026.6.1 |
| 105-ent-headroom-comp-tokenomics | `agw-headroom-comp` | v2026.6.1 |
| 11-xaa-cross-app-access | `agw-xaa` | pin at implement (OSS MCP auth + Keycloak; see demo PLAN.md) |
| 16-api-key-scoped-token-budgets | (standalone Docker, no kind cluster) | v1.5.0 |
| 17-codex-kind | `agw-codex` | v1.4.1 (OSS Codex + Entra JWT; kind twin of `14-codex`) |
| 17-k8s-api-key-scoped-token-budgets | `agw-token-budgets` (standalone image; apply-only YAML) | v1.5.0 |
| 18-standalone-cel-block-curl | (standalone Docker, no kind cluster) | v1.5.0 |

Demo `07-bedrock-llm` is split into three subfolders — `standalone/` (binary), `oss/` (K8s, cluster `agw-bedrock`), and `enterprise/` (K8s, cluster `agw-bedrock-ent`, Enterprise v2026.6.3 + Solo UI 0.5.0) — all fronting **Amazon Bedrock** (Claude, `us-east-2`). One `AGENTGATEWAY_LICENSE_KEY` + AWS creds live in a shared gitignored `07-bedrock-llm/.env` (populated by `07-bedrock-llm/provision-aws.sh`). A single `AUTH_MODE={creds|apikey}` toggles between AWS SigV4 credentials and an AWS Bedrock long-term API key; the `AgentgatewayBackend` (`spec.ai.provider.bedrock`) is otherwise identical across all three.

Demo `11` is the **XAA / Enterprise-Managed Authorization** education + lab (MCP EMA, ID-JAG, Keycloak). Plan/test/education docs land first; runtime deploy follows PLAN Phase 1–2.

Demo `16` is the **v1.5.0 standalone API-key-scoped token/dollar budget** lab (`llm.policies.apiKey.keys[].budgets` + `config.database` SQLite). Folder is `16-…` because `11-…` is already XAA. Demo `17-k8s-api-key-scoped-token-budgets` is the Kind apply-only twin (same feature, standalone image in-cluster; no helper scripts). `17-codex-kind` already occupies a `17-` prefix.

Demo `18` is the **v1.5.0 standalone CEL HTTP authorization** lab (`llm.policies.authorization.rules` with `deny: request.headers["user-agent"].contains("curl")`). Docker bind-mount of `config.yaml`; no kind cluster. Kubernetes `AgentgatewayPolicy` uses a different schema (`action: Deny` + `matchExpressions`) — README appendix only.

Demos `103`, `104`, and `105` use the **Enterprise** AgentGateway (`EnterpriseAgentgatewayBackend`,
`entMcp.toolMode` Standard/Search/Code) from `oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/`, not the OSS charts above. `104` and `105` front an **external** MCP server (GitHub's hosted `api.githubcopilot.com/mcp`) — no in-cluster MCP pod. `105` forks `104` and adds a second knob: a local **Headroom** compression proxy (https://github.com/headroomlabs-ai/headroom) the harness routes the LLM call through (`HEADROOM=on` + `LLM_URL`), to test whether AGW's catalog savings and Headroom's payload compression *stack*. Headroom defaults to compression OFF — `105`'s `run_matrix.sh`/`test.sh` launch it with compression explicitly enabled.

Gateway API CRDs are `v1.5.0` everywhere. Namespace is `agentgateway-system`. Helm charts come from `oci://cr.agentgateway.dev/charts/` (`agentgateway-crds` + `agentgateway`).

## Running a K8s demo

```bash
cd 03-loadbalancing-models          # pick a demo
export OPENAI_API_KEY="..."         # set the keys that demo's deploy.sh checks for
export ANTHROPIC_API_KEY="..."      # (load-balancing demos need both)
./deploy.sh
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80 &
./test.sh
./cleanup.sh                        # tears down the kind cluster
```

`17-k8s-api-key-scoped-token-budgets` is apply-only (no `deploy.sh`). Follow that folder's README: `kubectl apply -f k8s/00-namespace.yaml` … then port-forward `svc/agentgateway` in namespace `agw-token-budgets` (`:4000` LLM, `:15000` admin).

## Secrets

API keys are passed as **environment variables**, never committed. `deploy.sh` reads them from the env and creates K8s Secrets; standalone demos use `${VAR}` placeholders in `config.yaml` that `run.sh` substitutes at runtime (via `envsubst`, falling back to `sed`) into a temp file so the real secret never lands in the tracked config. The root `.env` and per-demo `.env` files are gitignored — keep real keys there, commit `.env.example` instead.

## Langfuse observability (08, 09)

AgentGateway emits OpenTelemetry traces using GenAI semantic conventions natively (no app code changes). These are pointed at a Langfuse OTLP endpoint (`.../api/public/otel/v1/traces`) via the `config.tracing` block (standalone) or equivalent. Auth is a base64 `public_key:secret_key` string in `LANGFUSE_AUTH_STRING`. Force `otlpProtocol: http` — Langfuse ingest does not support gRPC.
