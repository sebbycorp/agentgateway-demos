# Demo 102: Enterprise Progressive Disclosure (MCP Search Mode) — Design

**Date:** 2026-06-19
**Demo dir:** `102-ent-progressive-discloure/`
**Status:** Approved design, pending implementation plan

## Goal

Build a self-contained AgentGateway **Enterprise** demo that deploys MCP **search
mode** (progressive disclosure) and produces **hard data proving token and cost
savings**. Progressive disclosure presents an LLM agent with only the tools it
needs at a given moment instead of the full tool catalog.

The mechanism: in **default mode** the gateway injects every upstream MCP tool's
JSON schema into the model's context on each call (N tools). In **search mode**
(`entMcp.toolMode: Search`) the gateway exposes only **two meta-tools** —
`get_tool` and `invoke_tool` — so the per-call tool-definition token cost stays
flat regardless of how many tools the backend fronts.

Reference: https://docs.solo.io/agentgateway/latest/mcp/tool-mode/search-mode/

## Success criteria

- A single `./deploy.sh` stands up the whole environment on a local `kind` cluster.
- `./test.sh` runs an A/B experiment and prints a summary proving search mode uses
  fewer prompt tokens / less cost than default mode.
- A `results.csv` / `results.json` ground-truth dataset is produced.
- A Grafana dashboard visualizes the savings, including a savings-vs-tool-count curve.
- `./cleanup.sh` tears everything down.

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| Proof method | A/B **live LLM calls** — same task run in both modes, read real `prompt_tokens`, convert to USD |
| MCP backend | **Synthetic tool-count knob** — custom MCP server exposing a configurable number of tools; sweep 10 / 50 / 100 |
| LLM | **OpenAI `gpt-4o-mini` routed through AgentGateway** (`/openai`), so the gateway emits GenAI token metrics natively |
| Observability | **Prometheus + Grafana** (OTel Collector receives AGW telemetry; harness also pushes labeled gauges via Pushgateway) |
| A/B harness | **Python** MCP client + OpenAI SDK |

## Architecture

Kind cluster `agw-progressive-disclosure`, built on the `101-k8s-ent-code-mode`
enterprise template: Solo Enterprise for AgentGateway `v2026.6.1`, Gateway API
`v1.5.0`, Solo UI (`management` chart), namespace `agentgateway-system`.

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

Both MCP routes point at the **same** synthetic server; only `entMcp.toolMode`
differs between the two `EnterpriseAgentgatewayBackend` resources. The tool-count
sweep is done by redeploying / scaling the synthetic server at TOOL_COUNT =
10/50/100 (3 instances or a rolling env change — implementation plan decides).

## Components

### 1. `deploy.sh`
Reuses the 101 enterprise install path (preflight checks for `kind`/`kubectl`/`helm`
and `AGENTGATEWAY_LICENSE_KEY`; installs Gateway API CRDs, Enterprise AGW CRDs +
control plane, Solo UI, proxy Gateway). Then adds:
- Synthetic MCP server Deployment + Service.
- Two `EnterpriseAgentgatewayBackend` resources (`toolMode` default vs `Search`) +
  their HTTPRoutes (`/mcp/default`, `/mcp/search`) with the `/mcp` URLRewrite.
- OpenAI LLM backend (`AgentgatewayBackend`, model `gpt-4o-mini`) + `/openai` route
  + `openai-secret` (requires `OPENAI_API_KEY`).
- Observability stack: OTel Collector, Prometheus (+ Pushgateway), Grafana with a
  pre-provisioned dashboard and datasource.

### 2. Synthetic MCP server (`mcp-server/`)
Small Python MCP server exposing `TOOL_COUNT` deterministic **echo** tools
(`tool_000 … tool_NNN`). Each tool carries a realistic-sized JSON input schema
(several typed parameters with descriptions) so per-tool token cost is
representative of real-world tools, not trivially small. Tools are no-op/echo →
runs are fully repeatable. `TOOL_COUNT` set via env var. Served over SSE
(matching the search-mode docs' target protocol).

### 3. A/B harness (`harness/run_ab.py`)
For each `(mode ∈ {default, search}) × (tool_count ∈ {10,50,100}) × (run ∈ 1..R)`:
1. Connect to the MCP route (`/mcp/default` or `/mcp/search`).
2. Fetch the advertised tool list.
3. Run a **fixed task prompt** via OpenAI through `/openai` with the tool list in
   context (`temperature=0`, seeded where supported). In search mode the agent
   uses `get_tool` → `invoke_tool`; in default mode it calls the tool directly.
4. Capture `prompt_tokens`, `completion_tokens`, `total_tokens` from usage.
5. Compute USD cost from a local price table (`base-costs.json` style).
6. Append a row to `results.csv` and `results.json`; push labeled gauges
   (`mode`, `tool_count`) to the Prometheus Pushgateway.

Sanity assertions: search-mode tool list length == 2; default-mode == TOOL_COUNT;
search `prompt_tokens` < default; both modes complete the task functionally.

### 4. Grafana dashboard
Provisioned JSON. Datasource: Prometheus.

**Design principle: simple and self-explanatory.** The dashboard must tell the
savings story to someone who has never seen it, at a glance. Concretely:
- A single screen, no scrolling, ordered top-to-bottom as a narrative.
- Lead with **3 big stat panels**: avg prompt tokens (default), avg prompt tokens
  (search), and the headline **% reduction** — color-coded green.
- Then the **savings-vs-tool-count curve** (two lines: default rises with tool
  count, search stays flat) — this is the "aha" visual.
- Then **$ saved per 1,000 calls** by tool count (bar).
- Every panel has a one-line description/subtitle in plain language explaining
  what it shows and why it matters. No raw metric names exposed to the viewer.
- Minimal panel count (≈5–6 total) — resist adding panels that don't advance the
  savings narrative.

### 5. Standard scripts
- `test.sh` — runs the harness end-to-end (full sweep), prints a summary table.
- `cleanup.sh` — deletes resources and the kind cluster.
- `step-by-step.sh` — annotated walkthrough version of deploy for live demos.
- `README.md` — architecture diagram, concepts, quick start, manual steps.

## Proof / data deliverable

- **Ground truth:** `results.csv` with columns
  `mode, tool_count, run, prompt_tokens, completion_tokens, total_tokens, usd_cost`.
- **Summary table** from `test.sh`, e.g.
  *"At 100 tools: default 4,820 prompt tok/call → search 310 tok/call = 93.6%
  reduction; $X saved per 1k calls."* (numbers illustrative; produced at runtime.)
- **Grafana** visualizes the same numbers, plus the live gateway-emitted GenAI
  metrics as a corroborating second source.

## Testing strategy

Determinism: fixed task prompt, `temperature=0`, seeded model where supported,
echo-only tools, R ≥ 5 repetitions averaged. Harness assertions as above. A fast
smoke path (`TOOL_COUNT=10`, `R=1`) for iteration; full sweep for the proof run.

## Conventions & secrets

- Follows repo per-demo conventions (CLAUDE.md): K8s mode, `deploy.sh` / `test.sh`
  / `cleanup.sh` / `step-by-step.sh` / `README.md`, pinned versions, own cluster
  name `agw-progressive-disclosure`, namespace `agentgateway-system`.
- Secrets via env vars only: `AGENTGATEWAY_LICENSE_KEY`, `OPENAI_API_KEY`. No keys
  committed; `.env.example` committed.

## Out of scope (YAGNI)

- Real third-party MCP servers (GitHub/etc.) — synthetic knob gives a cleaner curve.
- Tempo / distributed tracing — Prometheus metrics are the proof.
- Multi-provider LLM comparison — single OpenAI model is sufficient.
- Authorization-based tool filtering demo — noted as a search-mode benefit but not
  measured here.
```
