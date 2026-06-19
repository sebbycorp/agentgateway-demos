# Progressive Disclosure v2 (Real-World) Implementation Plan

> **For agentic workers:** Implement task-by-task. Live cluster `agw-progressive-disclosure` is already running; verification is LIVE (not offline). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Extend demo 102 to a credible real-world proof: 4 tool modes, 2 frontier models, real cache-aware costing, honest tradeoff metrics (round-trips/latency/net tokens/success), business $/month projection, and a data-rich Deep-Dive Grafana dashboard — while keeping the v1 headline dashboard simple.

**Architecture:** Add an Anthropic LLM backend (`/anthropic`, `claude-sonnet-4-6`), expand the deploy loop to 12 MCP backends (4 modes × 3 counts), refactor the harness to sweep provider × mode × tool_count × cache-state(cold/warm) capturing the full token/latency/round-trip breakdown, add a projection script, and a second Grafana dashboard showing as much of the captured data as possible.

**Tech Stack:** Enterprise AGW v2026.6.1; OpenAI gpt-4o-mini + Anthropic claude-sonnet-4-6 (both via AGW, OpenAI-compatible schema); Python 3.13 harness (httpx, mcp, prometheus_client); Prometheus/Pushgateway/Grafana.

## Global Constraints

- Cluster `agw-progressive-disclosure`, namespace `agentgateway-system`, obs namespace `observability`.
- Models: OpenAI `gpt-4o-mini` (route `/openai`), Anthropic `claude-sonnet-4-6` (route `/anthropic`).
- **Both providers use the OpenAI-compatible schema through AGW** (verified live): POST `{"model":"","messages":[...],"tools":[...]}`; response `choices[0].message`, `usage` with `prompt_tokens`, `completion_tokens`, `prompt_tokens_details.cached_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`. `"model":""` lets the backend inject the model.
- toolMode enum: `Standard` (full list), `Search` (get_tool+invoke_tool), `Code` (run_code), `CodeSearch` (get_tool+run_code). Advertised tool counts: N / 2 / 1 / 2.
- Tool-count sweep: 10, 50, 100.
- Secrets via gitignored `.env` → Secret (sed); never commit. Keys: `AGENTGATEWAY_LICENSE_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`.
- Headline dashboard (`dashboard.json`) stays simple; Deep-Dive (`dashboard-deepdive.json`) maximizes data shown. Every panel keeps a plain-language description.

## Spike findings (live, baked in)
- Anthropic via AGW = OpenAI-compatible; one client adapter for both providers.
- `usage` exposes both OpenAI (`cached_tokens`) and Anthropic (`cache_read/creation_input_tokens`) cache fields.
- All 4 modes accepted by the CRD and reachable; tool surfaces confirmed (N/2/1/2).
- Tracing already enabled (deploy.sh Step 5b) — spans land in `platformdb.otel_traces_json`.
- `k8s/anthropic.yaml` already authored and applied live (backend "successfully accepted").

---

## Task 1: Anthropic backend wired into deploy.sh

**Files:** Modify `102-ent-progressive-discloure/deploy.sh` (add ANTHROPIC_API_KEY preflight + apply step); `k8s/anthropic.yaml` (exists, verify).

- [ ] **Step 1:** Add `ANTHROPIC_API_KEY` to the preflight check block (alongside OPENAI_API_KEY): require it set, error if missing.
- [ ] **Step 2:** After the OpenAI step (Part C), add Part C2:
```bash
echo ""
echo "==> Step 8b: Configuring Anthropic LLM backend (/anthropic)..."
sed "s|__ANTHROPIC_API_KEY__|${ANTHROPIC_API_KEY}|" "${SCRIPT_DIR}/k8s/anthropic.yaml" | kubectl apply -f-
```
- [ ] **Step 3:** `bash -n deploy.sh`. Then live: `set -a; . ./.env; set +a; sed "s|__ANTHROPIC_API_KEY__|${ANTHROPIC_API_KEY}|" k8s/anthropic.yaml | kubectl apply -f-` and confirm backend status `Backend successfully accepted` (already verified).
- [ ] **Step 4:** Commit `feat(102): anthropic LLM backend + deploy wiring`.

---

## Task 2: Expand deploy to 4 tool modes

**Files:** Modify `deploy.sh` Part B loop.

- [ ] **Step 1:** Change `for mode in default search` → `for mode in standard search code codesearch`, and the mapping to: standard→`Standard`, search→`Search`, code→`Code`, codesearch→`CodeSearch`. Route paths become `/mcp/<mode>-<count>` (e.g. `/mcp/codesearch-100`). This yields 12 backends + 12 routes.
- [ ] **Step 2:** `bash -n deploy.sh`; live `./deploy.sh` (idempotent) and verify: `kubectl get enterpriseagentgatewaybackend -n agentgateway-system` shows 12 backends with the 4 toolModes across 3 counts.
- [ ] **Step 3:** Verify advertised tool counts through the gateway for one count (10): standard=10, search=2, code=1, codesearch=2.
- [ ] **Step 4:** Commit `feat(102): deploy all four tool modes (Standard/Search/Code/CodeSearch)`.

---

## Task 3: Pricing model v2

**Files:** `harness/pricing.json`.

- [ ] **Step 1:** Replace with per-model rates (USD per 1K tokens). Use current list prices; include a comment/source date.
```json
{
  "gpt-4o-mini":      { "input_per_1k": 0.00015, "cached_input_per_1k": 0.000075, "output_per_1k": 0.0006 },
  "claude-sonnet-4-6":{ "input_per_1k": 0.003,    "cache_write_per_1k": 0.00375, "cache_read_per_1k": 0.0003, "output_per_1k": 0.015 }
}
```
- [ ] **Step 2:** `python3 -c "import json;json.load(open('harness/pricing.json'))"`.
- [ ] **Step 3:** Commit `feat(102): cache-aware pricing for both models`.

---

## Task 4: Harness v2 — provider sweep, cache/latency/round-trip capture

**Files:** `harness/run_ab.py` (refactor), optional `harness/providers.py` (thin).

**Interfaces produced:** `results.csv` columns:
`provider,model,mode,tool_count,run,cache_state,advertised_tools,first_call_prompt_tokens,total_prompt_tokens,completion_tokens,cached_tokens,cache_write_tokens,cache_read_tokens,total_tokens,llm_calls,latency_ms,usd_cost_uncached,usd_cost_cached,task_ok`

- [ ] **Step 1:** Config: `PROVIDERS={openai:/openai, anthropic:/anthropic}` (route + model label); `MODES=[standard,search,code,codesearch]`; `TOOL_COUNTS=[10,50,100]`; `CACHE_STATES=[cold,warm]`; `RUNS`.
- [ ] **Step 2:** One OpenAI-compatible request builder/sender (works for both providers). Normalize `usage` → dict: `prompt_tokens, completion_tokens, cached_tokens (=prompt_tokens_details.cached_tokens), cache_write_tokens (=cache_creation_input_tokens), cache_read_tokens (=cache_read_input_tokens)`.
- [ ] **Step 3:** Tool loop unchanged in spirit (bounded), but: count `llm_calls`; time the whole task with `time.perf_counter()` → `latency_ms`; capture `first_call_prompt_tokens` (sentinel). For **code/codesearch** modes the tools are `run_code`/`get_tool`; the model writes JS — execute tool calls via MCP as before (the gateway exposes them as normal MCP tools).
- [ ] **Step 4:** Cold/warm: for each (provider,mode,count,run), execute the task, tag `cold`; immediately re-execute identical task, tag `warm`. (Back-to-back keeps Anthropic's 5-min TTL warm.)
- [ ] **Step 5:** **cache_control sub-spike (live, inside this task):** run a default/standard-100 task on Anthropic twice; check whether `cache_read_tokens>0` on the warm run with no special request fields. If zero, add Anthropic `cache_control` to the request (e.g. mark the tools/system block) and re-test. Document whichever works in a code comment. (OpenAI caching is automatic for ≥1024-tok prompts — no action.)
- [ ] **Step 6:** Cost: `usd_cost_uncached` = all prompt tokens at full input rate + output; `usd_cost_cached` = (uncached prompt - cached)·input + cached·cached_rate (OpenAI) / cache_read·read_rate + cache_write·write_rate + rest·input (Anthropic) + output. Helper reads rates from pricing.json by model.
- [ ] **Step 7:** Write results.csv/json; push gauges labeled `provider,mode,tool_count,cache_state` for: first_call_prompt_tokens, total_tokens, llm_calls, latency_ms, usd_cost_cached, usd_cost_uncached, advertised_tools, task_ok(as 1/0).
- [ ] **Step 8:** Assertions: advertised_tools == {standard:count, search:2, code:1, codesearch:2}. Warm OpenAI standard-100 shows cached_tokens>0.
- [ ] **Step 9:** `py_compile`; live smoke `RUNS=1 PROVIDERS=openai MODES=standard,search TOOL_COUNTS=10`. Then a fuller live run.
- [ ] **Step 10:** Commit `feat(102): provider/mode/cache sweep with latency + round-trip capture`.

---

## Task 5: Realistic multi-tool task

**Files:** `harness/run_ab.py` (TASK + success check).

- [ ] **Step 1:** Replace the single-tool task with a deterministic multi-step one that needs 2–3 tools, e.g. *"Call tool_003 with text='alpha' number=1; call tool_011 with text='beta' number=2; then reply with both returned strings joined by ' | '."* (Choose tool indices present at every tool_count, i.e. < 10.)
- [ ] **Step 2:** `task_ok` = both echo strings present in the final answer/among tool results. Keep robust substring `echoed` checks per result.
- [ ] **Step 3:** Live-verify the task completes in all 4 modes on at least OpenAI (record task_ok; Code-mode failures are recorded honestly, not fatal).
- [ ] **Step 4:** Commit `feat(102): realistic multi-tool agent task`.

---

## Task 6: Business cost projection

**Files:** `harness/projection.py`, output `harness/projection.csv`.

- [ ] **Step 1:** Read results.csv; aggregate avg `usd_cost_cached` and `usd_cost_uncached` per (provider,mode,cache_state). For volumes [10000,50000,200000] calls/day compute $/day and $/month (×30), and $ saved vs Standard (same provider/cache_state).
- [ ] **Step 2:** Write projection.csv (`provider,mode,cache_state,calls_per_day,usd_per_day,usd_per_month,usd_saved_per_month_vs_standard`) and print a summary table.
- [ ] **Step 3:** Push gauges `agw_proj_usd_per_month{provider,mode,cache_state,volume}`.
- [ ] **Step 4:** `py_compile`; live run after a sweep; sanity-check numbers. Commit `feat(102): $/month cost projection`.

---

## Task 7: Deep-Dive dashboard (maximize data shown)

**Files:** `observability/dashboard-deepdive.json`; `deploy.sh` Part D (second ConfigMap).

- [ ] **Step 1:** Build a multi-row dashboard, each panel with a description, covering as much captured data as possible:
  - Row "Token footprint": first_call_prompt_tokens by mode×tool_count (bar), per provider.
  - Row "Tradeoffs": llm_calls (round-trips) by mode; latency p50/p95 by mode (use the latency gauge); net total_tokens by mode.
  - Row "Caching": usd_cost_cached vs usd_cost_uncached by mode (cold vs warm); cached_tokens / cache_read_tokens by mode×provider.
  - Row "Success": task_ok rate by mode×provider.
  - Row "Business": agw_proj_usd_per_month by mode×volume (both providers).
  - A template variable for `provider` so the viewer can flip OpenAI/Anthropic.
- [ ] **Step 2:** `deploy.sh` Part D: create ConfigMap `agw-dashboard-deepdive` from the file, label `grafana_dashboard=1`. (Grafana sidecar auto-loads.)
- [ ] **Step 3:** `json.load` validates; `bash -n deploy.sh`; live: apply configmap + restart/grafana reload; confirm both dashboards listed via Grafana API.
- [ ] **Step 4:** Commit `feat(102): deep-dive dashboard (modes, cache, latency, projection)`.

---

## Task 8: README v2 + test.sh sweep

**Files:** `README.md`, `test.sh`.

- [ ] **Step 1:** test.sh: run the full provider×mode×cache sweep then projection.py; print both summary tables; keep the python>=3.10 auto-select.
- [ ] **Step 2:** README: document the 4 modes, both models, cache-aware columns, cold/warm, projection, and the two dashboards; add `ANTHROPIC_API_KEY` to prereqs.
- [ ] **Step 3:** `bash -n test.sh`. Commit `docs(102): README v2 + full-sweep test.sh`.

---

## Final: live full sweep + whole-branch review
- [ ] Run the complete sweep on the live cluster; confirm results.csv populated across all dimensions, both dashboards show data, projection numbers sane, traces in UI.
- [ ] Whole-branch review (opus) for cross-file consistency (metric names ↔ dashboard queries, pricing keys ↔ cost fns, route names ↔ harness).

## Self-Review notes
- Coverage: tradeoff(T4,T7), 4 modes(T2,T4,T7), real cache both providers(T3,T4), projection(T6,T7), UI tracing(shipped) → all mapped.
- Simplification from spike: single OpenAI-compatible adapter; cache fields from unified usage. Reflected in T4.
- Honest unknowns flagged with live sub-spikes: Anthropic cache_control (T4 S5), Code-mode task success (T5 S3) — recorded, not assumed.
