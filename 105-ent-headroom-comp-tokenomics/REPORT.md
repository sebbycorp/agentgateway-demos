# 105 — Report: do AgentGateway tool modes and Headroom stack?

> **🚧 MEASURED RESULTS PENDING A LIVE RUN.** This report states the thesis, method, and the
> hypotheses we expect to confirm or refute. The **Findings** section is intentionally empty
> until `./run_matrix.sh` has run on a live cluster (needs your license + OpenAI spend). Fill
> Findings from `harness/results.jsonl`, the matrix console output, and `judge.py`. Run it
> **3 times** and report the range, as demo 104 does — cross-run variance is real here.

## The question

AgentGateway tool modes (104) cut the **tool-catalog tax**. Headroom cuts the **content
payload**. They optimize different layers, so in principle the savings should **stack**. This
demo measures whether they actually do, on the identical 104 GitHub-MCP workload, across a
small and a large repo — and whether answer quality survives compression.

## Method

- 3 AGW modes × Headroom OFF/ON × {small, large} repo = 12 cells, 5 questions each.
- Cost is gpt-5.5 list-price, cache-aware. Quality is an LLM judge (0–5) vs the Standard/OFF
  answer for the same question.
- Headroom runs as its local proxy with **compression explicitly enabled** (its default is
  off), forwarding to AGW `/openai`.

## Hypotheses (to confirm/refute, not assume)

1. **Small repo → Headroom adds little.** Small JSON payloads give content compression
   nothing to bite on. Expected: ON ≈ OFF on the small repo; an honest neutral result that
   *explains why* payload compression needs payloads.
2. **Large repo → Headroom helps, and stacks with Search.** Expected biggest stacked win:
   **Search + Headroom ON** (AGW removes the catalog tax; Headroom removes the large result
   JSON).
3. **Code + Headroom overlap.** Code already returns summary-only, so compression on top may
   show diminishing returns.
4. **Quality holds.** ON-cells should score within tolerance of the OFF baseline. Any drop is
   flagged, not buried.

## Findings

_(empty — run `./run_matrix.sh` ×3 and fill this in)_

| Claim | Small repo | Large repo |
|-------|-----------|-----------|
| Headroom ON cheaper than OFF (Standard) | _TBD_ | _TBD_ |
| Headroom ON cheaper than OFF (Search) | _TBD_ | _TBD_ |
| Headroom ON cheaper than OFF (Code) | _TBD_ | _TBD_ |
| Biggest stacked win (cheapest cell overall) | _TBD_ | _TBD_ |
| Quality held (no cell dropped vs baseline) | _TBD_ | _TBD_ |

## Verdict

_(empty — answer the headline question with measured numbers + cross-run range, and state any
fairness caveats, e.g. if the Headroom build's flags differed or if a quality drop appeared.)_

## See also

- Demo **104** — AGW tool modes alone on this exact GitHub workload (no compression).
- Demo **103** — the small-catalog (F5) contrast, where Search *loses* over a conversation.
- [`COST-ANALYSIS.md`](./COST-ANALYSIS.md) — the full 12-cell table.
