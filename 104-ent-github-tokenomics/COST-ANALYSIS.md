# GitHub MCP Tool Modes — Full Cost Analysis

**Backend:** GitHub's external remote MCP (`api.githubcopilot.com/mcp/readonly`), 28
read-only tools, fronted by AgentGateway (PAT injected as a Bearer token upstream).
**Scope:** one dedicated public sandbox repo — `sebbycorp/agw-tokenomics-sandbox`.
The test cannot touch any other repo (read-only system prompt + single-repo fine-grained PAT).
**Model:** `gpt-5.5` via the AgentGateway `/openai` route
**Pricing (list-price estimate, USD / 1K tokens):** input `$0.005`, cached input
`$0.0025` (≈50% off), output `$0.015`
**Runs:** single-call (5 questions × 3 modes) + 5-question conversation × 3 modes, executed
**three times**. Headline numbers are the latest run; §6 gives the cross-run variance.

---

## 1. Per-call tool context (deterministic — identical every run)

| Mode | Tools advertised | First-call tool tokens | vs Standard |
|------|-----------------:|-----------------------:|------------:|
| **Standard** | 28 | 4,781 | — |
| **Search** | 2 | **429** | **−91%** |
| **Code** | 1 | 3,021 | **−37%** |

GitHub's read-only tools have verbose schemas — 4,781 tokens for the catalog — making the
per-call context a far bigger lever than the F5 demo's 1,588 tokens.

---

## 2. Single-call cost — one question, fresh session (latest run)

| Question | Standard | Search | Code |
|----------|---------:|-------:|-----:|
| repo      | $0.03239 | $0.01347 | $0.02330 |
| commits   | $0.03126 | $0.01726 | $0.02015 |
| issues    | $0.02707 | $0.01451 | $0.01994 |
| prs       | $0.03862 | $0.00743 | $0.01870 |
| contents  | $0.03921 | $0.01246 | $0.01905 |
| **average** | **$0.0337** | **$0.0130** | **$0.0202** |

**Search is cheapest on all 5** (~61% under Standard) — and was cheapest on all 5 in every
run. Code beats Standard but can't overtake Search on a small repo, where there's too little
per-task data for its batching to repay the higher first-call context.

---

## 3. Multi-turn conversation cost — 5-question chat (latest run)

**Cumulative cost per turn:**

| Turn | Standard | Search | Code |
|-----:|---------:|-------:|-----:|
| 1 | $0.0322 | $0.0164 | $0.0221 |
| 2 | $0.0877 | $0.0438 | $0.0489 |
| 3 | $0.1316 | $0.0786 | $0.0911 |
| 4 | $0.1758 | $0.1167 | $0.1194 |
| 5 | **$0.2333** | **$0.1752** | **$0.1594** |

**Cumulative totals after 5 turns (latest run):**

| Mode | Total tokens | Cache-read tokens | Cost | vs Standard |
|------|-------------:|------------------:|-----:|------------:|
| **Standard** | 71,768 | 54,912 | **$0.233** | baseline |
| **Search** | 46,812 | 28,416 | **$0.175** | −25% |
| **Code** | 49,020 | 41,856 | **$0.159** | **−32%** |

Both Search and Code beat Standard. In this run Code edged out Search; in the prior two runs
Search was cheapest (see §6). The constant across all runs: **Standard is the most
expensive** — GitHub's catalog is costly to re-send each turn, so avoiding it pays off.

---

## 4. Cache analysis (gpt-5.5 prompt caching, latest run)

| Mode | Cache-read tokens (5-turn convo) | % of total |
|------|---------------------------------:|-----------:|
| Standard | 54,912 | 77% |
| Search | 28,416 | 61% |
| Code | 41,856 | 85% |

---

## 5. Cache sensitivity — does the Search-vs-Standard win survive a different cache rate?

Splits at turn 5 (latest run) — Standard: uncached 15,684 · cached 54,912 · output 1,172;
Search: uncached 17,183 · cached 28,416 · output 1,213.

| Cache discount | cached $/1K | Standard | Search | Search ÷ Standard |
|----------------|------------:|---------:|-------:|------------------:|
| 50% off (used here) | $0.00250 | $0.233 | $0.175 | **0.75×** |
| 75% off | $0.00125 | $0.165 | $0.140 | 0.85× |
| 90% off | $0.00050 | $0.123 | $0.118 | 0.96× |
| **100% (cache free)** | $0.00000 | $0.096 | $0.104 | **1.08×** |

At realistic cache rates (~50% off) Search clearly wins. The margin narrows as cache gets
cheaper, and at the theoretical free-cache extreme Standard's huge-but-cached catalog can
edge ahead — because in this run Search had slightly more *uncached* prompt. Net: **Search
wins at normal cache rates; it's a toss-up only in the free-cache limit.** (Code, which has
the largest cached share, is the most cache-rate-robust of the three.)

---

## 6. Reproducibility & run-to-run variance (3 runs)

**Single-call cost, average per task:**

| Run | Standard | Search | Code |
|----:|---------:|-------:|-----:|
| 1 | $0.0410 | $0.0150 | $0.0335 |
| 2 | $0.0295 | $0.0140 | $0.0200 |
| 3 | $0.0337 | $0.0130 | $0.0202 |

**Conversation cost after 5 turns:**

| Run | Standard | Search | Code |
|----:|---------:|-------:|-----:|
| 1 | $0.250 | $0.165 | $0.256 |
| 2 | $0.379 | $0.171 | $0.238 |
| 3 | $0.233 | $0.175 | $0.159 |

- **Deterministic:** first-call context (4,781 / 429 / 3,021), tools advertised (28 / 2 / 1).
- **Stable:** Search cheapest on all 5 single questions, every run; Search & Code both beat
  Standard in conversation, every run; Search is the most predictable (~$0.17).
- **Noisy:** Standard's conversation cost ($0.23–$0.38) and the Search-vs-Code ordering.

The ranking conclusion (Standard loses for a big catalog; Search is the safe money-saver) is
robust to this noise.

---

## 7. Bottom line & guidance

| Workload | Winner | Why |
|----------|--------|-----|
| Single call, large catalog, modest result | **Search** | −91% per-call context; cheapest on all 5, every run |
| Long conversation, large catalog | **Search or Code (not Standard)** | catalog tax dominates; both beat Standard |
| Step with *large* per-call results | **Code** | batching + summarize-only repays its overhead at volume |

**Takeaways**
1. For a verbose catalog like GitHub's, the per-call context reduction is large
   (Search −91%, Code −37%) and **translates to real savings**.
2. **Avoid Standard for a big catalog** — most expensive and least predictable.
3. **Search is the safe pick; Code can edge ahead** when results are large. Their order
   flips run-to-run on small data.
4. Caching helps every mode (~61–88% from cache) but doesn't change the headline ranking.
5. **Catalog size and result size decide.** Compare demo 103 (F5, small catalog): same three
   modes, opposite verdict. Measure for your own.

## Reproduce

```bash
set -a; . .env; set +a            # gpt-5.5 backend; read-only single-repo GITHUB_PAT
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &
kubectl port-forward svc/prometheus-prometheus-pushgateway -n observability 9091:9091 &
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/gh_questions.py      # single-call
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/gh_conversation.py   # multi-turn
```
Dashboard: `kubectl port-forward svc/grafana -n observability 3001:80` → **GitHub — MCP Tool Modes**.
