# GitHub MCP Tool Modes — Full Cost Analysis

**Backend:** GitHub's external remote MCP (`api.githubcopilot.com/mcp/readonly`), 28
read-only tools, fronted by AgentGateway (PAT injected as a Bearer token upstream).
**Scope:** one dedicated public sandbox repo — `sebbycorp/agw-tokenomics-sandbox`.
The test cannot touch any other repo (read-only system prompt + single-repo fine-grained PAT).
**Model:** `gpt-5.5` via the AgentGateway `/openai` route
**Pricing (list-price estimate, USD / 1K tokens):** input `$0.005`, cached input
`$0.0025` (≈50% off), output `$0.015`
**Runs:** single-call (5 questions × 3 modes) + one ongoing 5-question conversation × 3 modes.
All runs succeeded. (Numbers below are the latest run; see §6 for run-to-run variance.)

---

## 1. Per-call tool context (deterministic)

The tool schema the gateway injects on the **first** call — identical every run:

| Mode | Tools advertised | First-call tool tokens | vs Standard |
|------|-----------------:|-----------------------:|------------:|
| **Standard** | 28 | 4,781 | — |
| **Search** | 2 | **429** | **−91%** |
| **Code** | 1 | 3,021 | **−37%** |

GitHub's read-only tools have verbose schemas — 4,781 tokens for the catalog — making
the per-call context a far bigger lever than the F5 demo's 1,588 tokens.

---

## 2. Single-call cost — one question, fresh session

| Question | Standard | Search | Code |
|----------|---------:|-------:|-----:|
| repo      | $0.03538 | $0.01725 | $0.02195 |
| commits   | $0.03120 | $0.01319 | $0.02006 |
| issues    | $0.02701 | $0.01455 | $0.02014 |
| prs       | $0.02675 | $0.01246 | $0.01870 |
| contents  | $0.02737 | $0.01252 | $0.01926 |
| **average** | **$0.0295** | **$0.0140** | **$0.0200** |

**Search is cheapest on all 5** (~53% under Standard). On one small repo there's little
result data, so Search's extra discovery round-trips are cheap and its −91% context wins.
Code beats Standard but can't overtake Search — its batching needs data volume to repay
the higher first-call context.

---

## 3. Multi-turn conversation cost — one ongoing 5-question chat

History accumulates; the gateway re-sends tool defs each turn.

**Cumulative cost per turn:**

| Turn | Standard | Search | Code |
|-----:|---------:|-------:|-----:|
| 1 | $0.1574 | $0.0166 | $0.1037 |
| 2 | $0.2073 | $0.0464 | $0.1341 |
| 3 | $0.2565 | $0.0823 | $0.1639 |
| 4 | $0.3086 | $0.1229 | $0.1964 |
| 5 | **$0.3792** | **$0.1714** | **$0.2381** |

**Cumulative totals after 5 turns:**

| Mode | Total tokens | Cache-read tokens | Cost | vs Standard |
|------|-------------:|------------------:|-----:|------------:|
| **Standard** | 125,681 | 111,104 | **$0.379** | baseline |
| **Search** | 49,223 | 35,712 | **$0.171** | **−55%** |
| Code | 72,157 | 61,312 | $0.238 | −37% |

**Search wins the conversation by 55%.** GitHub's catalog is so expensive to re-send each
turn that avoiding it (Search) beats the extra round-trips — the opposite of the F5 demo
(103), where the small catalog meant the re-sent transcript dominated and Search cost
~4.8× *more*. Code beats Standard too here, but stays above Search.

---

## 4. Cache analysis (gpt-5.5 prompt caching)

| Mode | Cache-read tokens (5-turn convo) | % of total |
|------|---------------------------------:|-----------:|
| Standard | 111,104 | 88% |
| Search | 35,712 | 73% |
| Code | 61,312 | 85% |

Standard's giant catalog is re-sent every turn and served heavily from cache — which is
why the cache rate matters to the margin (next section).

---

## 5. Cache sensitivity — does the Search win survive a different cache rate?

Splits at turn 5 — Standard: uncached 11,727 · cached 111,104 · output 2,850;
Search: uncached 12,051 · cached 35,712 · output 1,460.

| Cache discount | cached $/1K | Standard | Search | Search ÷ Standard |
|----------------|------------:|---------:|-------:|------------------:|
| 50% off (used here) | $0.00250 | $0.379 | $0.171 | **0.45×** |
| 75% off | $0.00125 | $0.240 | $0.127 | 0.53× |
| 90% off | $0.00050 | $0.157 | $0.100 | 0.64× |
| **100% (cache free)** | $0.00000 | $0.101 | $0.082 | **0.81×** |

**Search beats Standard at every cache rate** (0.45×–0.81×). The margin narrows as cache
gets cheaper, because Standard's enormous-but-cached catalog approaches free — but Search
still wins even with free cache, since it emits fewer uncached and output tokens too.

*(Set `IN_PER_1K`/`CACHED_IN_PER_1K`/`OUT_PER_1K` to your contracted rates to recompute.)*

---

## 6. Reproducibility & run-to-run variance

Measured across two live runs:

- **Deterministic:** first-call context (Standard ~4,781 / Search ~429 / Code ~3,021),
  tools advertised (28 / 2 / 1). Identical every run.
- **Stable findings:** Search cheapest on all 5 single questions; Search wins the
  conversation by a wide margin; Standard most expensive.
- **Noisy (model nondeterminism + cache warmth):** absolute conversation dollars. Observed
  ranges — Standard **$0.25–$0.38**, Search **$0.16–$0.17** (tightest), Code **$0.24–$0.26**.
  Standard's spread is widest because the model sometimes loops over the big catalog.

The conclusion is robust to this noise: **Search is the money-saver for a large catalog.**

---

## 7. Bottom line & guidance

| Workload | Winner | Why |
|----------|--------|-----|
| Single call, large catalog, modest result | **Search** | −91% per-call context; cheapest on all 5 |
| Long conversation, large catalog | **Search** | catalog tax dominates; −55%, robust to cache rate |
| Step with *large* per-call results | **Code** | batching + summarize-only repays its overhead only at volume |

**Takeaways**
1. For a verbose catalog like GitHub's, the per-call context reduction is large
   (Search −91%, Code −37%) and **translates to real savings** — Search wins per call and
   across a conversation when results are modest.
2. **Code is not automatically the winner.** It pays a higher first-call context and only
   overtakes Search when each task returns enough data for batching to matter.
3. Caching helps every mode (~73–88% served from cache) but does not change the ranking.
4. **Catalog size and result size are the deciding variables.** Compare with demo 103
   (F5, small catalog): same three modes, opposite verdict. Measure for your own.

## Reproduce

```bash
set -a; . .env; set +a            # gpt-5.5 backend; read-only single-repo GITHUB_PAT
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &
kubectl port-forward svc/prometheus-prometheus-pushgateway -n observability 9091:9091 &
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/gh_questions.py      # single-call
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/gh_conversation.py   # multi-turn
```
Dashboard: `kubectl port-forward svc/grafana -n observability 3001:80` → **GitHub — MCP Tool Modes**.
