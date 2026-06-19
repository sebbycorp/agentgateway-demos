# 102 — Enterprise Progressive Disclosure (MCP Search Mode)

AgentGateway's **MCP search mode** ("progressive disclosure") replaces the full tool
catalog that a model sees on each call with exactly two meta-tools — `get_tool` and
`invoke_tool`. Instead of injecting every upstream tool's JSON schema into the context
on every request, the gateway lets the model look up only the tools it actually needs.
This keeps the per-call tool-definition token cost flat regardless of how many tools
the backend MCP server exposes, producing measurable savings in both prompt tokens and
USD cost that scale with tool-catalog size. This demo proves those savings with live
LLM calls: it runs an A/B sweep across default mode and search mode at 10, 50, and 100
tools, captures real `prompt_tokens` from OpenAI's API, and surfaces the data in a
pre-provisioned Grafana dashboard.

## Architecture

```
                          kind: agw-progressive-disclosure
 ┌────────────────────────────────────────────────────────────────┐
 │  agentgateway-proxy (Gateway API)                                │
 │   ├─ /mcp/default  → EntBackend(toolMode: default) ┐             │
 │   ├─ /mcp/search   → EntBackend(toolMode: Search)  ┘→ synthetic  │
 │   │                                                  MCP server   │
 │   │                                                  (TOOL_COUNT  │
 │   │                                                   env knob)   │
 │   └─ /openai       → AgentgatewayBackend(OpenAI gpt-4o-mini)     │
 │                                                                   │
 │  AGW ──OTLP──▶ OTel Collector ──▶ Prometheus ──▶ Grafana         │
 │                                       ▲                           │
 │                              Pushgateway (harness gauges)         │
 └────────────────────────────────────────────────────────────────┘
                       ▲
        Python A/B harness (MCP client + OpenAI SDK)
        → results JSON/CSV  + pushes gauges to Prometheus
```

Three synthetic MCP server instances run concurrently with `TOOL_COUNT` set to 10, 50,
and 100. For each instance two `EnterpriseAgentgatewayBackend` resources are deployed —
one in default mode, one in search mode — each reachable at `/mcp/<mode>-<count>`
(e.g. `/mcp/default-100`, `/mcp/search-100`). The OpenAI LLM backend is exposed at
`/openai`.

## Prerequisites

Tools (must be on `PATH`):

| Tool | Purpose |
|------|---------|
| `kind` | Local Kubernetes cluster |
| `kubectl` | Cluster interaction |
| `helm` | Chart installs |
| `docker` | Build + load the synthetic MCP server image |
| `python3` (>= 3.10) | A/B harness (`test.sh` auto-selects the newest python3.x and creates a venv; the `mcp` client needs 3.10+) |

Environment variables:

| Variable | Description |
|----------|-------------|
| `AGENTGATEWAY_LICENSE_KEY` | Solo Enterprise license — https://www.solo.io/company/contact |
| `OPENAI_API_KEY` | OpenAI key used by the A/B harness via the `/openai` gateway route |

## Quick Start

```bash
# 1. Copy and fill in the environment file
cp .env.example .env
# Edit .env and set AGENTGATEWAY_LICENSE_KEY and OPENAI_API_KEY, then:
set -a; . .env; set +a

# 2. Deploy the full stack (kind cluster + AGW + MCP servers + observability)
./deploy.sh

# 3. Run the A/B sweep (full 10/50/100 tool-count sweep, 5 runs each)
# NOTE: test.sh self-manages the proxy (8080) and pushgateway (9091) port-forwards.
# Do NOT start those manually — it would collide ("address already in use").
./test.sh

# 4. View the Grafana dashboard — this is the only forward you need to start manually:
kubectl port-forward svc/grafana -n observability 3001:80
# Open http://localhost:3001  (username: admin / password: admin)

# 6. Tear everything down
./cleanup.sh
```

`test.sh` writes `harness/results.csv` and `harness/results.json`, pushes labeled
gauges to Prometheus, and prints a savings summary table directly in the terminal.

## What the Data Proves

The A/B harness writes one row per `(mode, tool_count, run)` to `harness/results.csv`.
The columns are:

| Column | Description |
|--------|-------------|
| `mode` | `default` or `search` |
| `tool_count` | Backend tool count (10, 50, or 100) |
| `run` | Run index within the sweep (1–5 by default) |
| `advertised_tools` | Tools returned by MCP `list_tools` — 100/50/10 in default mode, always **2** in search mode |
| `first_call_prompt_tokens` | Prompt tokens on the **first** LLM call — this is the cleanest measure of tool-definition overhead because it includes only the system context and the full tool list before any tool results are appended |
| `total_prompt_tokens` | Cumulative prompt tokens across all turns (initial + tool results) |
| `completion_tokens` | Total completion tokens across all turns |
| `total_tokens` | `total_prompt_tokens + completion_tokens` |
| `usd_cost` | USD cost at gpt-4o-mini list prices (input + output) |
| `task_ok` | Whether the model successfully called `tool_007` and returned the echo |

`first_call_prompt_tokens` is the key isolation metric: it captures only the
tool-schema injection cost without contamination from tool results. In default mode
this grows linearly with the number of backend tools. In **search mode it stays
flat** — always reflecting the token cost of the two meta-tools (`get_tool` and
`invoke_tool`) regardless of whether 10 or 100 tools are behind the gateway.

The terminal summary printed by `test.sh` shows the percentage reduction at each
tool count, for example:

```
=== Search-mode savings summary ===
   10 tools: default  X,XXX tok -> search  XXX tok = XX.X% reduction
   50 tools: default  X,XXX tok -> search  XXX tok = XX.X% reduction
  100 tools: default  X,XXX tok -> search  XXX tok = XX.X% reduction
```

## Grafana Dashboard

The provisioned dashboard "MCP Search Mode — Token & Cost Savings" has five panels:

1. **Avg prompt tokens — DEFAULT mode** (stat, red): first-call tokens when all tools
   are advertised.
2. **Avg prompt tokens — SEARCH mode** (stat, green): first-call tokens with only
   `get_tool` + `invoke_tool` advertised.
3. **Prompt-token reduction** (stat, percent): headline savings metric,
   green when above 50%.
4. **Prompt tokens vs tool count — the aha curve** (time-series): default mode rises
   with tool count; search mode stays flat — the gap is the saving.
5. **Avg USD cost per task by mode & tool count** (bar gauge): real dollar cost at
   gpt-4o-mini list prices; search bars are dramatically shorter.

## Key Config

The search-mode behavior is enabled by a single field on the
`EnterpriseAgentgatewayBackend`:

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: mcp-search-100
  namespace: agentgateway-system
spec:
  entMcp:
    toolMode: Search          # <-- this is the only difference from default mode
    targets:
    - name: synthetic
      static:
        host: mcp-server-100.agentgateway-system.svc.cluster.local
        port: 80
        protocol: SSE
```

Setting `toolMode: Search` causes the gateway to replace the upstream tool list with
`get_tool` + `invoke_tool` on every `/list_tools` response. The upstream tools are
still fully callable via `invoke_tool`; the model just discovers them on demand
rather than receiving all definitions upfront.

Reference: https://docs.solo.io/agentgateway/latest/mcp/tool-mode/search-mode/

## Demo Cluster / Versions

| Demo | Cluster name | AGW version | Gateway API |
|------|--------------|-------------|-------------|
| 102-ent-progressive-discloure | `agw-progressive-disclosure` | `v2026.6.1` | `v1.5.0` |

## Cleanup

```bash
./cleanup.sh
```

Deletes the `agw-progressive-disclosure` kind cluster and all resources with it.
