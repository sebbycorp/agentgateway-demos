# 105 — Do AgentGateway tool modes and Headroom *stack*?

**Date:** 2026-06-22
**Status:** Approved design
**Author:** Sebastian Maniak (with Claude)
**Sequel to:** demo 103 (F5 local MCP), demo 104 (GitHub external MCP)

---

## 1. Problem & thesis

Demo 104 showed that AgentGateway (AGW) MCP **tool modes** (Standard / Search / Code)
cut token cost by shrinking the **tool-catalog tax** — the 28 GitHub MCP tool schemas
re-injected every turn (~4,781 tok) and the orchestration round-trips.

[Headroom](https://github.com/headroomlabs-ai/headroom) claims 60–95% token savings on
the *same kind of workload* ("GitHub issue triage 73%"). But Headroom attacks a
**different layer**: it compresses the **content payload** — the verbose GitHub JSON
results, files, and conversation history — before they reach the LLM. It is *not* a
substitute for AGW tool modes; it is a compression layer on the LLM request body.

| | Reduces | Mechanism |
|---|---|---|
| **AGW tool modes** | tool-catalog tax + round-trips | Search: 28 tools → 2 meta-tools (−91% catalog). Code: N calls → 1 round-trip, summary-only result |
| **Headroom** | content/result payload + history | ML/AST/JSON compressors (SmartCrusher, CodeCompressor, Kompress model), reversible |

**Thesis to test:** because they touch different layers, the savings should **stack**.
The 105 experiment measures whether Headroom adds savings *on top of* AGW tool modes on
the identical 104 GitHub-MCP workload — and whether answers stay correct.

This is explicitly **not** a "which one wins" bake-off. They are complementary; the
question is whether stacking them compounds.

---

## 2. Architecture — two independent knobs in one cluster

```
                            ┌─ Headroom OFF ─► AGW /openai ──► OpenAI
harness ──build request────►┤
 (catalog baked in per      └─ Headroom ON ──► Headroom proxy ─► AGW /openai ─► OpenAI
  AGW tool mode)                                (compresses tool-result JSON + history)
        │
        └──/mcp/gh-{std,search,code}── AGW (toolMode) ──TLS+PAT──► GitHub remote MCP
                                                                    (read-only, 28 tools)
```

- **Knob 1 — AGW `toolMode`** (acts on the MCP catalog, identical to 104): three backends
  `gh-std` / `gh-search` / `gh-code` already defined in `104/k8s/github.yaml`.
- **Knob 2 — Headroom** (acts on the LLM request body): OFF = harness posts to AGW
  `/openai`; ON = harness posts to the Headroom proxy, which compresses and forwards to
  AGW `/openai`.
- They touch **different arrows** — that is *why* stacking is possible and is the thesis.

### Integration point in the harness

The 104 harness hard-codes `LLM = GW + "/openai"`. 105 makes this a single env var:

```python
LLM = os.environ.get("LLM_URL", GW + "/openai")
```

- `HEADROOM=off` → `LLM_URL` unset → posts to AGW `/openai` (104 behaviour).
- `HEADROOM=on`  → `LLM_URL=http://localhost:8787/...` (Headroom proxy) → proxy forwards
  to AGW `/openai` as its upstream.

The AGW tool-mode (catalog) effect is **independent** of which LLM URL is used, because
the catalog is baked into the request body by the harness from the MCP `tools/list`
response — not added by the `/openai` route. This keeps the two knobs cleanly orthogonal.

> **⚠️ Implementation-time verification (first task in the plan):** confirm the Headroom
> proxy supports a **custom upstream base URL** so it can target AGW `/openai`. The README
> says it "intercepts requests to any LLM provider," so it should. **Fallback** if it can
> only target OpenAI directly: in the ON case point Headroom at OpenAI directly
> (`harness → Headroom → OpenAI`). The AGW catalog effect is unchanged (catalog is in the
> request body); we lose only AGW tracing on the ON-path LLM call, which we note in the
> report. Either way the experiment remains valid.

---

## 3. The experiment — 12 cells

**3 AGW modes × 2 Headroom states × 2 repos = 12 cells.** Each cell runs both the
single-question suite and the 5-turn conversation, mirroring 104.

| AGW mode \ Headroom | OFF | ON |
|---|---|---|
| **Standard** | baseline (= 104) | catalog tax present + payload compressed |
| **Search** | AGW best (= 104) | both stacked — expected biggest win on large repo |
| **Code** | summarize-only | does compression still help when results pre-summarized? |

**Repos (both read-only, pinned):**
- **small** — the 104 sandbox `sebbycorp/agw-tokenomics-sandbox` (apples-to-apples vs 104).
- **large** — a larger read-only repo with many issues/PRs/commits/file contents, giving
  Headroom heavy JSON payloads to compress. Selected at implementation time; pinned via
  `GH_REPO` and the read-only PAT. Candidate: a well-known public repo the sandbox PAT can
  read, or a second owned repo seeded with content. **Decision deferred to the plan.**

### Per-cell metrics

Reuse 104's accounting and add quality:
- input / cached / output tokens, **USD cost** (gpt-5.5 list-price, cache-aware, same
  constants as 104, env-overridable).
- first-call tool tokens, LLM round-trips, `task_ok`.
- **LLM-judge quality score** (new) — see §4.

---

## 4. Answer-quality verification (LLM-judge)

Headroom changes what the model sees, so cost numbers are meaningless without a fairness
check. A separate judge model scores every answer so we never compare cheaper-but-wrong
against AGW.

- **Baseline answer** per question = the **Standard / Headroom-OFF** answer (the
  uncompressed, full-catalog reference).
- For every other cell's answer to the same question, a judge model (via the same
  `/openai` route, OFF-path so the judge call itself is never compressed) returns a
  0–5 correctness/completeness score plus a one-line rationale, comparing against the
  baseline answer.
- Recorded as `agw_hr_quality_score` alongside cost. A cell that is cheaper but scores
  materially lower is flagged in the report, not celebrated.

The judge prompt is fixed and deterministic (temperature handling matches the backend's
constraints, per 104's `LLM_NO_TEMPERATURE`). Judge model id configurable; defaults to the
demo backend model.

---

## 5. What gets built (mostly copied from 104)

New directory `105-ent-headroom-comp-tokenomics/`:

1. **`deploy.sh`** — copy of 104's (kind cluster **`agw-headroom-comp`**, Enterprise AGW
   `v2026.6.1`, Gateway API `v1.5.0`, namespace `agentgateway-system`, OpenAI backend,
   GitHub std/search/code backends) **plus** a step that installs and launches the
   Headroom proxy (pip `headroom-ai[all]`, `headroom proxy --port 8787`, upstream → AGW
   `/openai`). Headroom runs as a local process alongside the port-forwards, not in-cluster
   (it is a stateless local proxy by design and keeps data on-device).
2. **Harness** (`harness/`) — fork 104's `gh_questions.py`, `gh_conversation.py`,
   `gh_chat.py`:
   - `LLM_URL` env switch (the Headroom knob).
   - `GH_REPO` already supported; add a `--repo small|large` convenience or rely on
     `GH_REPO`.
   - new `judge.py` module: LLM-judge scoring against the baseline answer file.
   - persist every answer to a results file so the judge can score and so answers are
     auditable.
3. **`run_matrix.sh`** — drives all 12 cells (3 modes × OFF/ON × 2 repos), captures the
   baseline answers first, runs the rest, invokes the judge, writes a combined
   cost+quality table (CSV + console).
4. **Observability** — reuse 104's pushgateway + Grafana (`observability/`); add an
   "Headroom OFF vs ON" comparison panel and a quality-score panel. New metric namespace
   `agw_hr_*` to avoid colliding with 104's `agw_ghq_*`.
5. **Docs** — `README.md` (framed "do they stack?"), `COST-ANALYSIS.md` (the 12-cell
   table + stacking analysis), `REPORT.md` (narrative + honest findings),
   `.env.example` (adds Headroom keys / model-cache notes), `cleanup.sh`,
   `step-by-step.sh`, `test.sh` (quick smoke of one question through OFF vs ON).

### Reuse vs new

| Reuse from 104 (copy + minimal edit) | New for 105 |
|---|---|
| `deploy.sh`, `k8s/openai.yaml`, `k8s/github.yaml` | Headroom install/launch step in `deploy.sh` |
| `gh_questions.py`, `gh_conversation.py`, `gh_chat.py` | `LLM_URL` switch, `judge.py`, results persistence |
| `observability/` dashboards, pushgateway wiring | OFF/ON + quality panels, `agw_hr_*` metrics |
| cost constants & accounting | `run_matrix.sh`, large-repo selection |

---

## 6. Safety (unchanged from 104)

- Read-only `/mcp/readonly` GitHub surface (28 `get_`/`list_`/`search_` tools, zero write
  tools). **Never** `/mcp/all/readonly`.
- Fine-grained, single-repo (or single-owner read-only) PAT. **Both** small and large
  repos must be readable by the PAT and pinned via `GH_REPO`.
- Secrets only in gitignored `.env` → Kubernetes `Secret`; manifests carry placeholders.
- Headroom proxy runs locally; data stays on-device (its stated design), so no repo data
  leaves the machine beyond the existing OpenAI calls.

---

## 7. Honest expected findings (to confirm, not assume)

- **Small repo:** Headroom likely adds **little** — small JSON payloads give its content
  compression nothing to bite on. An honest negative/neutral result, and it explains *why*
  payload compression needs payloads.
- **Large repo:** Headroom should help most where results are big. Expected biggest
  stacked win: **Search + Headroom ON** (AGW removes the catalog tax; Headroom removes the
  large result JSON). **Code + Headroom** may show overlap/diminishing returns because Code
  already returns summary-only.
- **Quality:** must stay within tolerance of baseline; any cell that drops is flagged.

The report states findings from measured runs with cross-run variance (3 runs, as 104
does), and explicitly calls out any cell where cheaper came at a quality cost.

---

## 8. Out of scope (YAGNI)

- Headroom's **library** and **MCP-server** deployment modes — only the **proxy** mode is
  tested (it is the transparent drop-in that wraps the LLM path without harness rewrites).
- Headroom's reversible-retrieval (`headroom_retrieve`) round-trip behaviour — noted but
  not separately benchmarked unless a cell's quality drop traces to it.
- Non-GitHub MCP servers; non-OpenAI LLMs.
- In-cluster deployment of Headroom (run it as the local proxy it is designed to be).

---

## 9. Success criteria

1. `deploy.sh` brings up the cluster + Headroom proxy idempotently; `test.sh` shows one
   question answered OFF vs ON with token counts.
2. `run_matrix.sh` produces a 12-cell cost+quality table (CSV + console) over both repos,
   reproducible across 3 runs.
3. `REPORT.md` answers the thesis with measured numbers: **do AGW tool modes and Headroom
   stack, and where?** — including the honest small-repo result and any quality flags.
4. No secret committed; read-only safety identical to 104.
