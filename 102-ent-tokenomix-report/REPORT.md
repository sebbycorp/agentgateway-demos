# Progressive Disclosure — Test Report

**Demo:** `102-ent-tokenomix-report`
**Date:** 2026-06-19
**Environment:** local `kind` cluster `agw-progressive-disclosure`, Solo Enterprise for AgentGateway `v2026.6.1`
**Run:** 2 providers × 4 tool modes × 3 tool counts × {cold, warm} × 2 runs = **96 task executions**

## What was tested

Progressive disclosure ("tool modes") changes how many MCP tool definitions the
gateway injects into an LLM's context:

- **Standard** — every tool's full JSON schema (N tools)
- **Search** — 2 meta-tools (`get_tool` + `invoke_tool`)
- **Code** — 1 tool (`run_code`, model writes JS to orchestrate tools)
- **CodeSearch** — 2 tools (`get_tool` + `run_code`)

A Python harness runs an identical **multi-tool agent task** (call `tool_003` and
`tool_005`, return both echoes) through each mode, on **two frontier models**
routed via AgentGateway's OpenAI-compatible API:

- OpenAI `gpt-4o-mini`
- Anthropic `claude-sonnet-4-6`

Each task is run **cold then warm** to exercise prompt caching. The harness
captures real token usage (incl. cache fields), USD cost, LLM round-trips,
latency, and task success. Ground truth: `harness/results.csv`.

## 1. Token savings — first-call tool-definition overhead (cold)

The cleanest metric: prompt tokens on the first LLM call (tool schemas only, no
tool results yet).

### OpenAI gpt-4o-mini
| Tools | Standard | Search | Code | CodeSearch |
|------:|---------:|-------:|-----:|-----------:|
| 10  | 1,334  | 264 (−80%)  | 1,636 (+23%) | 541 (−59%) |
| 50  | 6,334  | 424 (−93%)  | 5,476 (−14%) | 701 (−89%) |
| 100 | 12,584 | 624 (−95%)  | 10,276 (−18%) | 901 (−93%) |

### Anthropic claude-sonnet-4-6
| Tools | Standard | Search | Code | CodeSearch |
|------:|---------:|-------:|-----:|-----------:|
| 10  | 2,818  | 849 (−70%)  | 2,439 (−13%) | 1,163 (−59%) |
| 50  | 11,818 | 1,009 (−91%) | 6,719 (−43%) | 1,323 (−89%) |
| 100 | 23,068 | 1,209 (−95%) | 12,069 (−48%) | 1,523 (−93%) |

**Search and CodeSearch stay nearly flat as the tool catalog grows; Standard
scales linearly.** That widening gap is the saving, and it grows with catalog size.

## 2. The honest tradeoff (the cost of disclosure)

Search/Code modes are not free — discovery and code-gen add round-trips and latency.

| Mode | LLM round-trips | Latency (100 tools, OpenAI) | Assessment |
|------|----------------:|----------------------------:|------------|
| Standard   | 2.0 | 3.7s | baseline |
| Search     | 2.0–3.0 | 4.0s | best all-round: huge token cut, ~no extra round-trips on OpenAI |
| Code       | 3–5 | 7.6–11s | **costs more at low tool counts**, only wins at ~100; slower |
| CodeSearch | 4–8 | 7.8–13s | big token cut, but most round-trips/latency |

**Key finding:** Code mode's `run_code` overhead exceeds the Standard tool list
until the catalog is large — it has a *crossover*. Search wins immediately and
at every scale.

## 3. Caching economics

- **OpenAI (real, measured):** the Standard tool block is auto-cached
  (`standard-100`: 21,824 → 25,088 cached tokens cold→warm). **But Search still
  beats *cached* Standard** — Search prompts (264–624 tok) fall below OpenAI's
  1024-token cache floor so they never cache, yet their absolute cost is so low it
  doesn't matter.
- **Anthropic (modeled):** a `promptCaching` policy (`cacheSystem` /
  `cacheMessages` / `cacheTools`) is applied in `k8s/anthropic.yaml`, but cache
  tokens were not surfaced through AGW `v2026.6.1`, so Anthropic cache economics
  are modeled in `projection.py` using published rates (cache write 1.25×, read 0.1×).

**Takeaway:** even with prompt caching fully working, progressive disclosure wins —
it avoids the cache-write premium and is immune to TTL/eviction misses.

## 4. Business projection — $/month at 200,000 agent calls/day

| Model | Standard | Search | Saved / month |
|-------|---------:|-------:|--------------:|
| OpenAI gpt-4o-mini | $8,620 | $1,270 | **$7,351** |
| Anthropic claude-sonnet-4-6 | $475,149 | $109,944 | **$365,205** |

Full breakdown (10k/50k/200k calls/day, all modes, cold/warm) in `harness/projection.csv`.

## 5. Task success — does disclosure preserve correctness?

| Standard | Search | Code | CodeSearch |
|---------:|-------:|-----:|-----------:|
| 24/24 | 24/24 | 23/24 | 24/24 |

Search and CodeSearch are as reliable as Standard. Code mode dropped one task —
an honest signal that code-generation is marginally less reliable.

## 6. Observability

- **Tracing:** an `EnterpriseAgentgatewayPolicy` exports GenAI spans to the Solo
  Enterprise UI (spans land in ClickHouse `platformdb.otel_traces_json`).
- **Grafana** (both verified resolving live data):
  - *MCP Search Mode — Token & Cost Savings* (headline)
  - *MCP Progressive Disclosure — Deep Dive* (token footprint, tradeoffs, caching,
    task success, business projection; `provider` + `cache_state` switches)

## 7. How to reproduce

```bash
cp .env.example .env   # set AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY
set -a; . .env; set +a
./deploy.sh
./test.sh              # full sweep + projection; writes results.csv / projection.csv
kubectl port-forward svc/grafana -n observability 3001:80   # http://localhost:3001 (admin/admin)
./cleanup.sh
```

Scope a quick run with env vars, e.g.
`RUNS=1 PROVIDERS=openai MODES=standard,search TOOL_COUNTS=10 ./test.sh`.

## Bottom line

At 100 tools, progressive disclosure (search mode) cuts the model's tool-context
**~95%** and saves **$7k–$365k/month** (model-dependent) at 200k calls/day — and it
**beats prompt caching** — with no loss of task success. Code modes add a
round-trip/latency cost and only pay off at large catalogs.
