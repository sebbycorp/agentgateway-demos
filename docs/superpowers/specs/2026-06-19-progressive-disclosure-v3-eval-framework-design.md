# Demo 102 v3: Progressive Disclosure Evaluation Framework — Design

**Date:** 2026-06-19
**Demo dir:** `102-ent-tokenomix-report/` (extends v2)
**Status:** Design for review
**Builds on:** v1 (search-mode proof) + v2 (4 modes, 2 models, cache-aware, projection)

## Goal

Turn the demo into a **clean, reusable evaluation framework** for MCP progressive
disclosure that exercises real-world conditions and surfaces *everything* in the
test output and dashboards. Five locked additions:

1. **Real MCP servers + real agentic task** — front real servers (GitHub MCP +
   credential-free: filesystem, fetch, time, memory) aggregated behind the gateway,
   plus synthetic padding to scale the catalog to 100/500 tools. Replace the
   contrived task with genuine tasks (incl. a flagship GitHub task).
2. **Agentic loops** — multi-step ReAct-style tasks of length K∈{1,3,5}; measure
   *cumulative* tokens / cost / round-trips across the loop per mode. Shows savings
   **compound with loop length** (Standard re-sends all tool defs every turn).
3. **Tool-selection accuracy at scale** — a labeled task suite (each task tagged
   with the expected correct tool[s]); measure top-1 selection accuracy per mode as
   distractor tools scale 10→100→500. Turns "cheaper" into "cheaper **and** correct".
4. **RBAC / per-identity tool filtering** — 3 JWT personas (readonly / team /
   admin) with different authorized tool subsets; prove `search`/`get_tool` only
   ever returns authorized tools; measure per-persona tokens + accuracy.
5. **Clean framework + README overhaul** — refactor the harness into a pluggable
   eval framework; rebuild the README to lead with the problem and the savings.

Cross-cutting: **statistical rigor** (temperature>0 sampling + error bars), and the
test/dashboards must **show all** dimensions.

## Decisions (locked with user)

| Decision | Choice |
|----------|--------|
| Real MCP servers | GitHub MCP (needs `GITHUB_TOKEN`) **+** credential-free (filesystem, fetch, time, memory) + synthetic padding for scale |
| Accuracy | Labeled task suite + distractor scaling (10→100→500); top-1 correct-tool accuracy per mode |
| RBAC | 3 JWT personas: readonly / team / admin |
| Agentic loops | Loop lengths K∈{1,3,5}; cumulative cost/tokens/round-trips per mode |
| Models | **OpenAI `gpt-5.5` + Anthropic `claude-opus-4-8`** (frontier; both live-verified through AGW). gpt-5.5 resolves to `gpt-5.5-2026-04-23`. |
| Modes | Standard / Search / Code / CodeSearch (from v2) |
| Folder | **Rename `102-ent-tokenomix-report/` → `102-ent-tokenomix-report/`** (first build step; cluster name/namespace unchanged) |
| Secrets | `GITHUB_TOKEN` + (frontier) `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` via gitignored `.env` → Secret (sed); never committed |
| Cost control | Frontier models are ~100× prior tiers. A full matrix on Opus can cost hundreds of $; the eval orchestrator MUST support scoping (subset models/modes/catalog/samples) and a token budget so full runs are opt-in. |

## Architecture

```
 agentgateway-proxy
  ├─ MCP backends (per tool mode), each aggregating:
  │    real:  github, filesystem, fetch, time, memory   (+ synthetic padding to N)
  │    modes: standard | search | code | codesearch
  │    routes: /mcp/<persona>/<mode>            (JWT-gated, per-persona tool filter)
  ├─ /openai     → gpt-4o-mini
  └─ /anthropic  → claude-sonnet-4-6
        │
   Eval framework (harness/):
     backends.py  — server registry (real + synthetic), aggregation, scale knob
     tasks.py     — labeled task suite (expected tools), agentic-loop tasks
     identities.py— 3 JWT personas + authorized tool sets
     eval.py      — orchestrator: provider × mode × persona × task × loopK × samples
     metrics.py   — normalized usage/accuracy/loop metrics → CSV + Pushgateway
     projection.py— $/month (extended with loop-length + per-persona)
   → results.csv  → Prometheus → Grafana (Eval dashboard + existing two)
```

## Components

### 1. Tool backends (`harness/backends.py` + `k8s/` + deploy.sh)
- Deploy real MCP servers: GitHub MCP (image + `GITHUB_TOKEN` secret), filesystem,
  fetch, time, memory (credential-free images). Aggregate them behind
  `EnterpriseAgentgatewayBackend` per mode (AGW MCP aggregation of multiple targets).
- Keep the synthetic server as **distractor padding** to scale the catalog to
  100/500 tools (the count that hurts), so accuracy/loops are tested at scale.
- **SPIKE (first task):** verify each real server connects through AGW MCP (SSE vs
  streamable), and that multi-target aggregation + tool naming works.

### 2. Agentic-loop test (`harness/tasks.py`, `eval.py`)
- Define multi-step tasks where step N+1 depends on step N's output (a real chain,
  not parallel). Run at K∈{1,3,5} steps.
- Capture per-loop: cumulative `prompt_tokens` (the compounding metric), total cost
  (cache-aware), `llm_calls`, latency, and completion. Compare modes — the headline:
  Standard's cumulative tokens ≈ K × (tool-def overhead); Search stays ~flat.

### 3. Accuracy harness (`harness/tasks.py`, `eval.py`, `metrics.py`)
- Each task carries `expected_tools`. After the run, record whether the model
  invoked the correct tool (top-1) — per mode, per distractor-scale point.
- Output: accuracy-vs-catalog-size curve per mode (does fuzzy search/get_tool still
  find the right tool among 500?).

### 4. RBAC (`k8s/rbac.yaml`, `harness/identities.py`)
- 3 JWT personas with authorized tool subsets (readonly ⊂ team ⊂ admin).
- AGW JWT auth + an authorization policy filtering tools per claim.
- **SPIKE:** find the exact AGW enterprise mechanism (JWT provider + RBAC/authz
  policy CRD) for per-identity MCP tool filtering — confirm `get_tool`/list only
  returns authorized tools. Assert: readonly sees fewer tools than admin; search
  results are filtered.
- Harness mints/sends a JWT per persona; records tokens + accuracy per persona.

### 5. Eval framework refactor (`harness/`)
- Split the monolithic `run_ab.py` into: `backends.py`, `tasks.py`, `identities.py`,
  `metrics.py`, `eval.py` (orchestrator), keeping `projection.py`. One results
  schema covering: provider, model, mode, persona, task_id, catalog_size, loop_k,
  sample, + all token/cache/latency/cost/accuracy/task_ok fields.
- Statistical rigor: `SAMPLES` runs at `temperature>0`; metrics push mean + stddev;
  dashboards show error bars where supported.

### 6. Dashboards (`observability/`)
- Keep headline (`dashboard.json`) simple and the v2 deep-dive.
- Add **`dashboard-eval.json`** ("Evaluation Framework"): accuracy-vs-catalog-size
  per mode; agentic-loop cumulative cost vs loop length; RBAC per-persona matrix
  (tools visible, tokens, accuracy); variance/error bars. Template vars: provider,
  persona, cache_state.

### 7. README overhaul (`README.md`)
- Lead with **the problem** (large tool catalogs blow up context every call, every
  loop turn), **the solution** (progressive disclosure), and the **headline savings**
  (numbers + the compounding-loop point) — above the fold.
- Then: the evaluation framework (what it measures and how), quick start, results,
  tool modes, RBAC, observability. Cleaner structure, scannable, with the money
  table near the top.

## Testing strategy
- Determinism for token counts (temp=0 path) + a separate `temperature>0` sampling
  path (SAMPLES≥5) for variance/error bars.
- Assertions: per-mode advertised-tool expectations; RBAC readonly⊂admin tool sets;
  agentic-loop cumulative tokens(standard) ≈ K × per-turn overhead; accuracy recorded
  (not gated — low accuracy is a finding).
- Offline checks (py_compile, json/yaml, bash -n) + live full eval on the cluster.

## Empirical findings already verified live (inform the build)
- **gpt-5.5 rejects `temperature: 0`** (only default 1 supported). The harness must
  omit temperature for gpt-5.5 → determinism drops → rely on `SAMPLES` averaging +
  error bars (aligns with the rigor goal). claude-opus-4-8 accepts temperature 0.
- **OpenAI cache floor confirmed ~1024 tokens** (a 1,018-token prompt did NOT cache;
  3,018+ did) AND **caching is best-effort** (two large prompts, 9k & 15k tokens,
  did not cache on the immediate warm call). Conclusion stands and is stronger:
  search/code prompts are below the floor (never cache), and even Standard can miss
  cache — so progressive disclosure's savings don't depend on caching luck.
- Both frontier models reachable through AGW via the OpenAI-compatible schema; `usage`
  carries cache fields for both conventions.

## Open risks (spiked early, not assumed)
1. **RBAC/JWT tool-filtering mechanism** — unverified; first RBAC task is a live spike.
2. **GitHub MCP + real-server transports through AGW** — verify connect/aggregate live.
3. **Agentic-loop determinism** — multi-step chains may vary; pin where possible,
   sample where not, report variance.
4. **Catalog scale to 500 tools** — perf of list_tools / search through AGW at scale.

## Out of scope (YAGNI)
- Real agent framework SDK integration (LangChain/Agents SDK) — the framework's own
  loop is sufficient to measure; revisit if asked.
- Sustained load/concurrency testing — separate effort; this is an eval framework,
  not a load test.
- More than 3 personas or >2 models.
