# 102 — Enterprise Progressive Disclosure (MCP Tool Modes)

AgentGateway's **MCP progressive disclosure** replaces the full tool catalog that a
model sees on each call with meta-tools that let the model discover only what it
needs. Instead of injecting every upstream tool's JSON schema into the context on
every request, the gateway can expose two meta-tools (`get_tool` + `invoke_tool`),
a single code-execution tool (`run_code`), or their combination — keeping the
per-call tool-definition token cost flat regardless of how many tools the backend
MCP server exposes. This produces measurable savings in prompt tokens and USD cost
that scale with tool-catalog size. **v2 now compares all four tool modes (Standard,
Search, Code, CodeSearch) across two frontier models — OpenAI gpt-4o-mini and
Anthropic claude-sonnet-4-6 — with cache-aware costing and a business $/month
projection.**

## Architecture

```
                          kind: agw-progressive-disclosure
 ┌────────────────────────────────────────────────────────────────┐
 │  agentgateway-proxy (Gateway API)                                │
 │   ├─ /mcp/standard-N   → EntBackend(toolMode: Standard)  ┐      │
 │   ├─ /mcp/search-N     → EntBackend(toolMode: Search)    │→ synthetic
 │   ├─ /mcp/code-N       → EntBackend(toolMode: Code)      │  MCP server
 │   ├─ /mcp/codesearch-N → EntBackend(toolMode: CodeSearch)┘  (TOOL_COUNT
 │   │                                                           env knob)  │
 │   ├─ /openai       → AgentgatewayBackend(OpenAI gpt-4o-mini)            │
 │   └─ /anthropic    → AgentgatewayBackend(Anthropic claude-sonnet-4-6)   │
 │                                                                           │
 │  AGW ──OTLP──▶ OTel Collector ──▶ Prometheus ──▶ Grafana                │
 │                                       ▲                                   │
 │                              Pushgateway (harness gauges)                 │
 └────────────────────────────────────────────────────────────────┘
                       ▲
        Python A/B harness (MCP client + OpenAI-compatible SDK)
        → results CSV/JSON  + pushes gauges to Prometheus
```

Three synthetic MCP server instances run concurrently with `TOOL_COUNT` set to 10,
50, and 100. For each instance four `EnterpriseAgentgatewayBackend` resources are
deployed — one per tool mode — each reachable at `/mcp/<mode>-<count>` (e.g.
`/mcp/search-100`). The OpenAI LLM backend is at `/openai` and the Anthropic
backend is at `/anthropic`.

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
| `ANTHROPIC_API_KEY` | Anthropic key for the second model (claude-sonnet-4-6) via the `/anthropic` gateway route |

## Quick Start

```bash
# 1. Copy and fill in the environment file
cp .env.example .env
# Edit .env and set AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY, and ANTHROPIC_API_KEY, then:
set -a; . .env; set +a

# 2. Deploy the full stack (kind cluster + AGW + MCP servers + observability)
./deploy.sh

# 3. Run the full A/B sweep (both providers x 4 modes x 3 counts x cold/warm, 3 runs each)
# NOTE: test.sh self-manages the proxy (8080) and pushgateway (9091) port-forwards.
# Do NOT start those manually — it would collide ("address already in use").
./test.sh

# To run a targeted subset, scope it with env vars:
# RUNS=1 PROVIDERS=openai MODES=standard,search TOOL_COUNTS=10 ./test.sh

# 4. View the Grafana dashboard — this is the only forward you need to start manually:
kubectl port-forward svc/grafana -n observability 3001:80
# Open http://localhost:3001  (username: admin / password: admin)

# 5. Tear everything down
./cleanup.sh
```

`test.sh` runs `run_ab.py` then `projection.py`. It writes `harness/results.csv`,
`harness/results.json`, and `harness/projection.csv`, pushes labeled gauges to
Prometheus, and prints a savings summary table directly in the terminal.

## Tool Modes

| Mode | `toolMode` | Tools advertised | How the model works |
|------|-----------|-----------------|---------------------|
| Standard | `Standard` | all N | Receives the full schema of every tool upfront |
| Search | `Search` | 2 | Gets `get_tool` + `invoke_tool`; looks up schemas by name on demand |
| Code | `Code` | 1 | Gets `run_code`; writes JS that orchestrates tool calls |
| CodeSearch | `CodeSearch` | 2 | Gets `get_tool` + `run_code`; looks up schemas then executes via code |

Each mode is deployed at tool counts 10/50/100 → 12 MCP backends; routes are
`/mcp/<mode>-<count>`.

**Honest tradeoff note:** Code/CodeSearch trade fewer advertised tools for extra
round-trips and code-gen tokens — at low tool counts they can cost MORE; they win
as the catalog grows. The Deep-Dive dashboard shows this crossover.

## What the Data Proves

The A/B harness writes one row per `(provider, model, mode, tool_count, run,
cache_state)` to `harness/results.csv`. Each task is run COLD then WARM (back-to-
back) to exercise prompt caching. The columns are:

| Column | Description |
|--------|-------------|
| `provider` | LLM provider (`openai` or `anthropic`) |
| `model` | Model name (`gpt-4o-mini` or `claude-sonnet-4-6`) |
| `mode` | Tool mode (`standard`, `search`, `code`, or `codesearch`) |
| `tool_count` | Backend tool count (10, 50, or 100) |
| `run` | Run index within the sweep |
| `cache_state` | `cold` (first call) or `warm` (repeat call to exercise caching) |
| `advertised_tools` | Tools returned by MCP `list_tools` — N in standard, 2 in search, 1 in code, 2 in codesearch |
| `first_call_prompt_tokens` | Prompt tokens on the first LLM call — cleanest measure of tool-definition overhead |
| `total_prompt_tokens` | Cumulative prompt tokens across all turns (initial + tool results) |
| `completion_tokens` | Total completion tokens across all turns |
| `cached_tokens` | OpenAI cached tokens (from `prompt_tokens_details.cached_tokens`) |
| `cache_write_tokens` | Anthropic cache creation tokens |
| `cache_read_tokens` | Anthropic cache read tokens |
| `total_tokens` | `total_prompt_tokens + completion_tokens` |
| `llm_calls` | Number of LLM round-trips required to complete the task |
| `latency_ms` | Wall-clock task latency in milliseconds |
| `usd_cost_uncached` | USD cost at list prices with no cache discount applied |
| `usd_cost_cached` | USD cost with real cache tokens applied (OpenAI) or modeled rates (Anthropic) |
| `task_ok` | Whether the model successfully called both required tools and returned the echoed strings |

`first_call_prompt_tokens` is the key isolation metric: it captures only the
tool-schema injection cost without contamination from tool results. In standard
mode this grows linearly with the number of backend tools. In **search/codesearch
mode it stays flat** — always reflecting the token cost of the two meta-tools
regardless of whether 10 or 100 tools are behind the gateway.

## Caching

**OpenAI (gpt-4o-mini):** caches automatically for prompts of 1024+ tokens, with
cached input priced at ~50% off list. The harness captures the real `cached_tokens`
field from the API response. Note that search, code, and codesearch prompts are
often shorter than the 1024-token cache floor so they may not cache — yet they are
still cheaper in absolute terms due to fewer advertised tool schemas.

**Anthropic (claude-sonnet-4-6):** a `promptCaching` policy
(`cacheSystem`/`cacheMessages`/`cacheTools`) is applied in `k8s/anthropic.yaml`,
but cache tokens were not observed through AGW v2026.6.1 during testing. As a
result, Anthropic cache economics are **modeled** in `projection.py` using
published rates (cache write 1.25× base input, cache read 0.1× base input). The
policy is applied as the documented, forward-compatible enablement and will
automatically reflect real savings when the gateway surfaces cache tokens.

## Cost Projection

`projection.py` (run automatically by `test.sh` after `run_ab.py`) reads
`results.csv`, averages the cache-aware cost per `(provider, mode, cache_state)`,
and projects $/day and $/month at three daily call volumes: **10k, 50k, and 200k
agent calls/day**. It also computes $ saved per month vs Standard mode for each
provider/mode/cache-state combination. Results are written to `harness/projection.csv`
and pushed as Grafana metrics (`agw_proj_usd_per_month`,
`agw_proj_usd_saved_per_month_vs_standard`) labeled by provider, mode, cache_state,
and volume.

## Grafana Dashboard

Two dashboards are provisioned.

**"MCP Search Mode — Token & Cost Savings"** (headline): five panels showing avg
prompt tokens in standard vs search mode, the percentage token reduction, the
aha-curve time-series where standard rises with tool count and search stays flat,
and avg USD cost per task by mode and tool count.

**"MCP Progressive Disclosure — Deep Dive"**: five rows with `provider` and
`cache_state` template variables:

1. **Tool-definition footprint** — first-call prompt tokens by mode and tool count;
   advertised tools per mode (standard=all, search=2, code=1, codesearch=2).
2. **Tradeoffs (round-trips / latency / net tokens)** — avg LLM round-trips per
   task, wall-clock latency by mode, and total tokens (prompt+completion) per task.
3. **Caching economics** — per-task USD cached vs uncached by mode; cold vs warm
   first-call token comparison.
4. **Task success** — success rate by mode, confirming that progressive disclosure
   preserves correctness.
5. **Business projection ($/month)** — projected monthly LLM spend by mode at
   10k/50k/200k calls/day, plus monthly $ saved vs Standard mode.

## Key Config

The tool mode is set by a single field on the `EnterpriseAgentgatewayBackend`:

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

The Anthropic backend uses an `AgentgatewayBackend` (standard AGW CRD) with an
`EnterpriseAgentgatewayPolicy` for prompt caching:

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

References:
- https://docs.solo.io/agentgateway/latest/mcp/tool-mode/search-mode/

## Tracing in the Solo Enterprise UI

`deploy.sh` Step 5b applies an `EnterpriseAgentgatewayPolicy` that turns on GenAI
distributed tracing. Without it the data-plane proxy emits no telemetry (its
config is empty) and the UI's **Tracing** view stays blank. The policy points the
proxy's OTLP exporter at the bundled `solo-enterprise-telemetry-collector`, which
writes spans into ClickHouse (`platformdb.otel_traces_json`) where the Solo UI
reads them.

```bash
# Open the Solo UI
kubectl port-forward svc/solo-enterprise-ui -n agentgateway-system 4000:80
# http://localhost:4000  — after running ./test.sh, the Tracing view shows
# the get_tool / invoke_tool spans for search-mode calls.

# Verify spans are landing:
kubectl exec -n agentgateway-system management-clickhouse-shard0-0 -c clickhouse \
  -- clickhouse-client --query "SELECT count() FROM platformdb.otel_traces_json"
```

> Note: this enables **traces**. Metrics export to ClickHouse is a separate
> pipeline and is not enabled by this policy.

## Demo Cluster / Versions

| Demo | Cluster name | AGW version | Gateway API |
|------|--------------|-------------|-------------|
| 102-ent-tokenomics | `agw-progressive-disclosure` | `v2026.6.1` | `v1.5.0` |

## Cleanup

```bash
./cleanup.sh
```

Deletes the `agw-progressive-disclosure` kind cluster and all resources with it.
