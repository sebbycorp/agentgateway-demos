# 102 — Enterprise Progressive Disclosure: MCP Tool Modes

Large MCP tool catalogs are a hidden token tax. Every time an LLM agent calls a
tool, the gateway injects the full JSON schema of every tool in the catalog into
the model's context — before a single word of useful work is done. In agentic
loops, that overhead compounds on **every turn**. At 100 tools on gpt-4o-mini,
the tool-definition block alone costs 12,584 prompt tokens per call. At 200,000
agent calls per day, that is over $8,000/month before the model does anything.

AgentGateway's **MCP progressive disclosure** solves this by replacing the full
tool catalog with meta-tools — `get_tool` + `invoke_tool` in Search mode — that
keep the advertised tool surface flat at 2 tools regardless of how many tools live
behind the gateway. The model looks up only what it needs, when it needs it.

---

## Headline Results (measured, gpt-4o-mini, cold)

### First-call token reduction at 100 tools

| Mode       | Prompt tokens | vs Standard |
|------------|-------------:|-------------|
| Standard   |       12,584 | baseline    |
| Search     |          624 | **−95%**    |
| CodeSearch |          901 | −93%        |
| Code       |       10,276 | −18%        |

> Source: `harness/results.csv`, cold runs, openai/gpt-4o-mini, catalog_size=100.

### Agentic-loop compounding (gpt-4o-mini, 50 tools, total prompt tokens)

| Mode     | K=1 (single loop) | K=3 (3-turn loop) |
|----------|------------------:|------------------:|
| Standard |            12,685 |            25,910 |
| Search   |               871 |             2,261 |

Token cost scales with every loop turn in Standard mode; Search stays near-flat.

### Business projection at 200,000 agent calls/day

Numbers below are from `harness/projection_v3.csv` (gpt-4o-mini, K=1 and K=3).

| Scenario                    | Standard $/month | Search $/month | Saved/month |
|-----------------------------|----------------:|---------------:|------------:|
| K=1 (single-shot)           |          $8,288 |           $964 |    **$7,324** |
| K=3 (3-turn agentic loop)   |         $15,295 |         $2,607 |   **$12,687** |

These are illustrative measured values based on a synthetic 2-tool task. Run the
full eval to produce frontier numbers across your actual task distribution and tool
catalog.

---

## Architecture

```
                    kind: agw-progressive-disclosure
 ┌──────────────────────────────────────────────────────────────────────┐
 │  agentgateway-proxy  (Gateway API / EnterpriseAgentGateway)          │
 │                                                                      │
 │  Synthetic (10/50/100 tools)                                         │
 │   ├─ /mcp/standard-N    → EnterpriseAgentgatewayBackend toolMode: Standard   ┐ │
 │   ├─ /mcp/search-N      → EnterpriseAgentgatewayBackend toolMode: Search     │→ mcp-server-N
 │   ├─ /mcp/code-N        → EnterpriseAgentgatewayBackend toolMode: Code       │  (TOOL_COUNT
 │   └─ /mcp/codesearch-N  → EnterpriseAgentgatewayBackend toolMode: CodeSearch ┘  env knob)
 │                                                                      │
 │  Real MCP servers                                                    │
 │   ├─ /mcp/real-everything  → everything server (13 tools, stdio+SSE) │
 │   ├─ /mcp/real-f5          → F5 BIG-IP wrapper (29 tools, StreamableHTTP)    │
 │   ├─ /mcp/real-f5-search   → F5 in Search mode   ┐  JWT RBAC applied │
 │   ├─ /mcp/real-f5-code     → F5 in Code mode     │  (admin/team/     │
 │   ├─ /mcp/real-f5-codesearch → F5 in CodeSearch  ┘   readonly)       │
 │   └─ /mcp/real-github      → GitHub (47 tools, hosted remote MCP)    │
 │                                                                      │
 │  LLM backends                                                        │
 │   ├─ /openai      → AgentgatewayBackend (gpt-5.5 via OPENAI_API_KEY) │
 │   └─ /anthropic   → AgentgatewayBackend (claude-opus-4-8 + prompt    │
 │                      caching policy)                                 │
 │                                                                      │
 │  AGW ──OTLP──▶ OTel Collector (solo-enterprise-telemetry-collector)  │
 │                   ├─▶ ClickHouse (Solo UI tracing view)              │
 │  Harness pushes gauges to:                                           │
 │  Prometheus ◀── Pushgateway ◀── Python eval harness                 │
 │      └──▶ Grafana (3 provisioned dashboards)                         │
 └──────────────────────────────────────────────────────────────────────┘
               ▲
 Python eval harness (MCP client + OpenAI-compatible SDK)
 harness/eval.py → results_v3.csv / results_v3.json
 harness/projection_v3.py → projection_v3.csv
```

---

## What Is Real About It

The eval framework exercises real infrastructure, not mocks:

| Backend | Tools | Notes |
|---------|------:|-------|
| `everything` (MCP reference server) | 13 | stdio bridged to SSE via `supergateway` |
| F5 BIG-IP wrapper | 29 | Live-authenticated StreamableHTTP MCP; per-mode sub-routes |
| GitHub (hosted remote MCP) | 47 | AGW injects PAT as upstream Bearer header |
| Synthetic | 10 / 50 / 100 | `TOOL_COUNT` env-knob; 4 mode variants each |

Two frontier models are tested:
- OpenAI `gpt-5.5` (default; override with `OPENAI_MODEL`)
- Anthropic `claude-opus-4-8` (default; override with `ANTHROPIC_MODEL`)

The v2 harness (eval.py) also measures **tool-selection accuracy** by unwrapping
meta-tool calls (`invoke_tool`, `run_code`) back to the upstream tool name, so
accuracy is comparable across modes.

---

## Tool Modes

| Mode       | `toolMode` value | Advertised tools | How the model uses it |
|------------|-----------------|:----------------:|-----------------------|
| Standard   | `Standard`       | N (all)          | Full schema of every tool injected upfront; token cost scales linearly with catalog size |
| Search     | `Search`         | 2                | `get_tool` + `invoke_tool`; model looks up schema by name on demand — token cost stays flat |
| Code       | `Code`           | 1                | `run_code`; model writes JS to orchestrate tool calls — inlines all signatures, so it is NOT a token-savings play at small catalogs |
| CodeSearch | `CodeSearch`     | 2                | `get_tool` + `run_code`; on-demand lookup then code execution — savings comparable to Search |

**Honest tradeoff:** Code and CodeSearch add round-trips and code-gen tokens. At
small catalogs they can cost more than Standard (see Code at 10 tools: +23% first-call
tokens vs Standard). Search wins immediately and at every catalog size. CodeSearch
follows a similar pattern to Search. Use the Deep-Dive Grafana dashboard to find
the crossover for your specific task and model.

---

## JWT RBAC on the F5 Backend

The F5 BIG-IP backend demonstrates AGW's MCP authorization capability. A JWT
`jwtAuthentication` policy (Strict mode) is applied to the F5 route; an
`mcp.authorization` policy on the backend filters which tools each role may see.

### Personas

| Persona  | JWT `role` claim | Visible tools (F5, 29 total) | Rule |
|----------|-----------------|-----------------------------:|------|
| admin    | `admin`         | 29 (all)                     | unconditional allow |
| team     | `team`          | 25 (approx.)                 | deny `delete_*` and `remove_*` prefixes |
| readonly | `readonly`      | 19 (approx.)                 | allow only `list_*`, `get_*`, `system*`, `failover_status`, `config_sync_status` |
| (none)   | —               | blocked                      | no token → request rejected |

Exact tool counts at runtime depend on the live F5 catalog; the numbers above
reflect the predicate logic in `k8s/f5-rbac.yaml` and `harness/identities.py`.

### Configuration snippet

```yaml
# k8s/f5-rbac.yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: { name: f5-rbac, namespace: agentgateway-system }
spec:
  targetRefs:
  - group: enterpriseagentgateway.solo.io
    kind: EnterpriseAgentgatewayBackend
    name: real-f5-std
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
          - 'jwt.role == "admin"'
          - 'jwt.role == "team" && !(mcp.tool.name.startsWith("delete_") || mcp.tool.name.startsWith("remove_"))'
          - 'jwt.role == "readonly" && (mcp.tool.name.startsWith("list_") || mcp.tool.name.startsWith("get_") || mcp.tool.name.startsWith("system") || mcp.tool.name == "failover_status" || mcp.tool.name == "config_sync_status")'
```

RS256 JWTs are generated offline by `harness/identities.py`
(`python3 -m harness.identities` → writes `.rbac_key.pem`, `.rbac_jwks.json`,
`.rbac_token_<role>.txt`). The JWKS public key is inlined in `f5-rbac.yaml`.

---

## Prerequisites

Tools (must be on `PATH`):

| Tool | Purpose |
|------|---------|
| `kind` | Local Kubernetes cluster |
| `kubectl` | Cluster interaction |
| `helm` | Chart installs |
| `docker` | Build + load the synthetic MCP server image |
| `python3` >= 3.10 | Eval harness (`test.sh` auto-selects newest python3.x and creates a venv) |

Environment variables:

| Variable | Required | Description |
|----------|:--------:|-------------|
| `AGENTGATEWAY_LICENSE_KEY` | yes | Solo Enterprise license — https://www.solo.io/company/contact |
| `OPENAI_API_KEY` | yes | OpenAI key for the `/openai` gateway route |
| `ANTHROPIC_API_KEY` | yes | Anthropic key for the `/anthropic` gateway route |
| `GITHUB_TOKEN` | yes (real-github) | GitHub PAT injected as upstream Bearer header |
| `F5_HOST` | yes (F5 backend) | F5 BIG-IP management URL, e.g. `https://172.16.10.10` |
| `F5_USERNAME` | yes (F5 backend) | BIG-IP admin username |
| `F5_PASSWORD` | yes (F5 backend) | BIG-IP admin password (injected via Kubernetes Secret) |

---

## Quick Start

```bash
# 1. Set environment variables
cp .env.example .env
# Edit .env, then:
set -a; . .env; set +a

# 2. Deploy the full stack
#    (kind cluster + Enterprise AGW + synthetic + real servers + observability)
./deploy.sh

# 3. Run the eval sweep
#    test.sh manages its own port-forwards (8080, 9091) — do NOT start those manually.
./test.sh
# Writes: harness/results_v3.csv, harness/results_v3.json, harness/projection_v3.csv
# Prints a savings summary table in the terminal.

# Scope a cheap smoke run:
# RUNS=1 PROVIDERS=openai MODES=standard,search CATALOG_SIZES=10 ./test.sh

# Full frontier run (all providers, modes, sizes, personas, loop depths):
# PROVIDERS=openai,anthropic MODES=standard,search,code,codesearch \
#   CATALOG_SIZES=10,50,100 PERSONAS=admin,team,readonly,none \
#   TASKS=two_tools,single_echo LOOP_KS=1,3 SAMPLES=3 ./test.sh

# 4. Open dashboards
kubectl port-forward svc/grafana -n observability 3001:80
# http://localhost:3001  (admin / admin)

kubectl port-forward svc/solo-enterprise-ui -n agentgateway-system 4000:80
# http://localhost:4000  (Solo UI — Tracing view shows get_tool / invoke_tool spans)

# 5. Tear down
./cleanup.sh
```

---

## The Evaluation Framework

The `harness/` directory is a standalone Python evaluation framework. All modules
are importable independently; `eval.py` is the orchestrator.

| Module | Role |
|--------|------|
| `eval.py` | Sweep orchestrator; env-knob configuration; writes results CSV/JSON; runs assertions |
| `backends.py` | Provider and MCP backend registry; `ProviderSpec` + `Backend` dataclasses |
| `identities.py` | RBAC personas (admin/team/readonly); JWT generation (RS256); token predicates |
| `tasks.py` | Task suite: `two_tools`, `single_echo`, `search_only`, `code_only`; `make_loop_task(k)` factory |
| `metrics.py` | Token usage normalization; USD cost calculation; Prometheus push |
| `projection_v3.py` | Reads results_v3.csv; projects $/day and $/month at 10k/50k/200k calls/day; writes projection_v3.csv |

### Env knobs for eval.py

| Variable | Default | Description |
|----------|---------|-------------|
| `GATEWAY_URL` | `http://localhost:8080` | AgentGateway proxy URL |
| `PUSHGATEWAY_URL` | `http://localhost:9091` | Prometheus Pushgateway URL |
| `PROVIDERS` | `openai,anthropic` | Comma-list of providers to sweep |
| `OPENAI_MODEL` | `gpt-5.5` | Override OpenAI model |
| `ANTHROPIC_MODEL` | `claude-opus-4-8` | Override Anthropic model |
| `MODES` | `standard,search,code,codesearch` | Tool modes to test |
| `CATALOG_SIZES` | `10,50,100` | Synthetic catalog sizes |
| `PERSONAS` | `none` | Comma-list: `admin`, `team`, `readonly`, `none` |
| `TASKS` | `two_tools,single_echo` | Task IDs (see `tasks.py`) |
| `LOOP_KS` | `0` | Agentic loop depths; `0` = single-shot tasks only |
| `SAMPLES` | `1` | Repeat each cell N times |
| `TARGETS` | `synthetic` | `synthetic`, `real-f5`, `real-github`, `real-everything` |
| `MAX_TOOL_TURNS` | `8` | Max LLM→tool round-trips per task |
| `RESULTS_CSV` | `harness/results_v3.csv` | Output CSV path |
| `RESULTS_JSON` | `harness/results_v3.json` | Output JSON path |

### results_v3.csv schema

One row per `(provider, model, mode, persona, target, catalog_size, task_id, loop_k, sample)`.

| Column | Description |
|--------|-------------|
| `first_call_prompt_tokens` | Prompt tokens on the first LLM call — the cleanest measure of tool-schema injection overhead |
| `total_prompt_tokens` | Cumulative prompt tokens across all turns |
| `completion_tokens` | Total completion tokens |
| `cached_tokens` | OpenAI cached tokens (real, from API response) |
| `cache_write_tokens` / `cache_read_tokens` | Anthropic cache creation/read tokens |
| `llm_calls` | LLM round-trips to complete the task |
| `latency_ms` | Wall-clock task latency |
| `usd_cost_uncached` / `usd_cost_cached` | USD cost without/with cache discount |
| `selected_tools` | Raw tool names called (incl. meta-tools) |
| `effective_tools` | Upstream tool targets after unwrapping meta-tools |
| `correct` | Top-1 tool match against expected_tools |
| `task_ok` | All expected tools effectively invoked (+ echo-string check for `two_tools`) |

`first_call_prompt_tokens` is the key isolation metric: it measures only
tool-schema injection cost before any tool results contaminate the context. In
Standard mode it grows linearly with catalog size. In Search/CodeSearch it stays
flat — always the cost of two meta-tool schemas, regardless of what is behind the
gateway.

---

## Observability

### Grafana dashboards (3 provisioned, auto-loaded)

| Dashboard | Key panels |
|-----------|------------|
| **MCP Search Mode — Token & Cost Savings** (headline) | Avg prompt tokens std vs search; % token reduction; "aha curve" (standard rises, search flat); avg USD cost by mode |
| **MCP Progressive Disclosure — Deep Dive** | Tool footprint; round-trip / latency tradeoffs; caching economics; task success rate; $/month projection at 10k/50k/200k calls/day |
| **Evaluation run** | Per-run metrics pushed by eval.py via Pushgateway |

Template variables on the Deep Dive dashboard: `provider`, `cache_state`.

### Solo Enterprise UI tracing

`deploy.sh` Step 5b applies an `EnterpriseAgentgatewayPolicy` that enables GenAI
distributed tracing. Without it the proxy emits no telemetry and the Tracing view
stays blank. Spans land in ClickHouse (`platformdb.otel_traces_json`) where the UI
reads them.

```bash
kubectl port-forward svc/solo-enterprise-ui -n agentgateway-system 4000:80
# http://localhost:4000 — the Tracing view shows get_tool / invoke_tool spans
# for Search-mode calls after ./test.sh completes.

# Verify spans are landing:
kubectl exec -n agentgateway-system management-clickhouse-shard0-0 -c clickhouse \
  -- clickhouse-client --query "SELECT count() FROM platformdb.otel_traces_json"
```

---

## Key Config Reference

### Tool mode (single field on EnterpriseAgentgatewayBackend)

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: mcp-search-100
  namespace: agentgateway-system
spec:
  entMcp:
    toolMode: Search          # Standard | Search | Code | CodeSearch
    targets:
    - name: synthetic
      static:
        host: mcp-server-100.agentgateway-system.svc.cluster.local
        port: 80
        protocol: SSE
```

### Prompt caching (Anthropic)

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: anthropic-prompt-caching
  namespace: agentgateway-system
spec:
  targetRefs:
  - kind: AgentgatewayBackend
    group: agentgateway.dev
    name: anthropic
  backend:
    ai:
      promptCaching:
        cacheSystem: true
        cacheMessages: true
        cacheTools: true
```

> Note: Anthropic cache tokens were not observed through AGW v2026.6.1 during
> testing. Anthropic cache economics in `projection_v3.py` are modeled using
> published rates (cache write 1.25×, read 0.1× base input price). The policy is
> applied as the documented, forward-compatible enablement.

References: https://docs.solo.io/agentgateway/latest/mcp/tool-mode/search-mode/

---

## Demo Cluster / Versions

| Demo | Cluster name | AGW version | Gateway API |
|------|--------------|-------------|-------------|
| 102-ent-tokenomics | `agw-progressive-disclosure` | `v2026.6.1` | `v1.5.0` |

---

## Cleanup

```bash
./cleanup.sh
```

Deletes the `agw-progressive-disclosure` kind cluster and all resources with it.
