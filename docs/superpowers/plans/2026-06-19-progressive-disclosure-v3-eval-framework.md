# Progressive Disclosure v3 — Evaluation Framework Implementation Plan

> Implement task-by-task on branch `feat/102-v3-eval-framework`. Live cluster `agw-progressive-disclosure` is up; verification is LIVE. Front-load spikes.

**Goal:** Turn demo `102-ent-tokenomics/` into a clean MCP progressive-disclosure **evaluation framework**: real MCP servers + GitHub, agentic loops (compounding savings), tool-selection accuracy at scale, 3-persona RBAC tool filtering, frontier models (gpt-5.5 + claude-opus-4-8), with the test and dashboards surfacing everything.

**Tech stack:** Enterprise AGW v2026.6.1; SSE-wrapped real MCP servers (supergateway) + synthetic padding; JWT auth + `mcp.authorization`; Python 3.13 eval framework; Prometheus/Grafana.

## Confirmed live (feasibility spikes done)
- MCP backend targets are network-based: `static` (host/port/SSE) or `selector` (by label). stdio reference servers need an SSE wrapper (supergateway/mcp-proxy) container.
- RBAC: `traffic.jwtAuthentication.providers[]` (JWT) + `backend.mcp.authorization` (`action`+`policy`) filters tools per identity.
- Frontier models reachable via OpenAI-compat schema. **gpt-5.5 rejects `temperature:0`** (omit it). OpenAI cache floor ~1024 tok and best-effort.
- Folder renamed to `102-ent-tokenomics/`; `.env` holds ANTHROPIC_API_KEY + GITHUB_TOKEN (gitignored, token verified).

## Global constraints
- Cluster `agw-progressive-disclosure`, ns `agentgateway-system`, obs ns `observability`.
- Models: `gpt-5.5` (no temperature override) + `claude-opus-4-8`. Pricing added to pricing.json.
- Modes: Standard/Search/Code/CodeSearch. Personas: readonly ⊂ team ⊂ admin.
- Secrets via gitignored `.env`→Secret(sed); never commit.
- **Cost:** frontier full-matrix runs are opt-in; eval orchestrator must support scoping (models/modes/catalog/samples) + token budget. Verification uses cheap/scoped runs.

---

## Task 1 (SPIKE+BUILD): one real MCP server through AGW via SSE wrapper
- Deploy a credential-free reference server (start with `@modelcontextprotocol/server-everything`) wrapped by `supergateway --stdio "npx -y @modelcontextprotocol/server-everything" --port 8000` in a Deployment+Service.
- `EnterpriseAgentgatewayBackend` (Standard) target `static` → that Service; HTTPRoute `/mcp/real-everything`.
- VERIFY live: `list_tools` through AGW returns the server's real tools. Record tool count + sample schema sizes.
- Commit `feat(v3): real MCP server (everything) via supergateway + AGW backend`.

## Task 2: deploy the real-server fleet + GitHub MCP
- Add filesystem, fetch, time, memory (credential-free, SSE-wrapped) + GitHub MCP (`github-mcp-server` with `GITHUB_PERSONAL_ACCESS_TOKEN` from `github-secret`, SSE-wrapped).
- Aggregate the fleet behind per-mode backends (multi-target `static`, or `selector` by label `mcp-real=true`), for all 4 modes.
- Keep synthetic server as distractor padding; backends to scale catalog to 100/500.
- VERIFY: aggregated `list_tools` returns union; search/code/codesearch tool surfaces correct; GitHub tools present.
- Commit.

## Task 3 (SPIKE+BUILD): JWT auth + 3-persona RBAC tool filtering
- Stand up a tiny JWT issuer (static JWKS configmap + pre-minted tokens per persona, or a minimal signer) so `traffic.jwtAuthentication` validates.
- Define `backend.mcp.authorization` policies filtering tools by JWT claim (e.g. `role`): readonly→read-only tool subset, team→+write, admin→all.
- VERIFY live with each persona's token: `list_tools`/`get_tool` returns only authorized tools; readonly⊂team⊂admin. Document the exact policy syntax found.
- Commit.

## Task 4: eval framework refactor (`harness/`)
- Split into `backends.py` (server/route registry, scale knob), `tasks.py` (labeled suite + agentic-loop tasks + expected_tools), `identities.py` (3 personas + tokens + authorized sets), `metrics.py` (normalized usage/accuracy/loop → CSV+Pushgateway), `eval.py` (orchestrator), keep `projection.py`.
- Provider adapter: OpenAI-compat for both; **omit temperature for gpt-5.5**; `SAMPLES` at temperature>0 → mean+stddev.
- Results schema: provider,model,mode,persona,task_id,catalog_size,loop_k,sample, + tokens/cache/latency/cost/llm_calls/selected_tool/expected_tool/correct/task_ok.
- Commit.

## Task 5: agentic loops + accuracy measurement (in `eval.py`/`tasks.py`)
- Agentic-loop tasks (dependent steps) at K∈{1,3,5}; capture cumulative prompt tokens/cost/round-trips per mode.
- Accuracy: record selected vs expected tool (top-1 correct) per mode × catalog_size {10,100,500}.
- VERIFY: scoped live run (cheap model) produces loop + accuracy rows; assertions (RBAC subsets, advertised-tool expectations).
- Commit.

## Task 6: frontier pricing + projection extension
- Add `gpt-5.5` + `claude-opus-4-8` rates (incl. cache rates) to pricing.json (mark prices + date; verify against current list prices).
- Extend `projection.py` with loop-length and per-persona projections.
- Commit.

## Task 7: Evaluation dashboard (`observability/dashboard-eval.json`) + wiring
- Panels (each described): accuracy-vs-catalog-size per mode; agentic-loop cumulative cost vs K per mode; RBAC per-persona matrix (tools visible/tokens/accuracy); variance/error bars. Template vars provider/persona/cache_state.
- deploy.sh: 3rd configmap `agw-dashboard-eval` + grafana provider. Verify both/all dashboards register + resolve data.
- Commit.

## Task 8: README overhaul + test.sh
- README leads with the problem (catalog bloat per call AND per loop turn), the solution, headline savings + compounding-loop point above the fold; then framework, quick start, modes, RBAC, observability.
- test.sh runs scoped eval by default (cheap model) with clear env knobs for the full frontier matrix.
- Commit.

## Final: scoped live eval + whole-branch review
- Run a scoped eval (cheap model, subset) to populate all dashboards; optionally one frontier subset with explicit OK.
- Whole-branch review (opus) for cross-file consistency.

## Open risks (handled in-task)
- supergateway/github-mcp-server SSE compatibility with AGW MCP client (Task 1/2 verify).
- JWT issuer + exact `mcp.authorization` policy syntax (Task 3 spike).
- Catalog scale to 500 tools perf; agentic-loop determinism (sample + report variance).
- Frontier cost (scoping + budget; full run opt-in).
