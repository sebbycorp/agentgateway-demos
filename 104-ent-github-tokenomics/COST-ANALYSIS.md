# GitHub MCP Tool Modes — Full Cost Analysis

**Backend:** GitHub's external remote MCP (`api.githubcopilot.com/mcp/readonly`), 28
read-only tools, fronted by AgentGateway (PAT injected as a Bearer token upstream).
**Scope:** one dedicated public sandbox repo — `sebbycorp/agw-tokenomics-sandbox`.
The test cannot touch any other repo (read-only system prompt + single-repo fine-grained PAT).
**Model:** `gpt-5.5` via the AgentGateway `/openai` route
**Pricing (list-price estimate, USD / 1K tokens):** input `$0.005`, cached input
`$0.0025` (≈50% off), output `$0.015`
**Runs:** single-call (5 questions × 3 modes) + one ongoing 5-question conversation × 3 modes.
All runs succeeded.

---

## 1. Per-call tool context (the structural difference)

Deterministic — the tool schema the gateway injects on the **first** call:

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
| repo      | $0.04561 | $0.01794 | $0.08342 |
| commits   | $0.04273 | $0.01733 | $0.02004 |
| issues    | $0.03888 | $0.01448 | $0.02627 |
| prs       | $0.03859 | $0.01247 | $0.01870 |
| contents  | $0.03921 | $0.01274 | $0.01926 |
| **average** | **$0.0410** | **$0.0150** | **$0.0335** |

**Search is cheapest on all 5** (~63% under Standard). On a single small repo there's
little result data, so Search's extra discovery round-trips are cheap and its −91%
context wins. Code's `repo` run is an outlier ($0.083, 5 calls) — the model fanned its
`run_code` out; on the other four Code is steady (~$0.02). Code's batching needs data
volume to repay its overhead, which a small repo doesn't provide.

---

## 3. Multi-turn conversation cost — one ongoing 5-question chat

History accumulates; the gateway re-sends tool defs each turn.

**Cumulative cost per turn:**

| Turn | Standard | Search | Code |
|-----:|---------:|-------:|-----:|
| 1 | $0.0460 | $0.0167 | $0.1189 |
| 2 | $0.0885 | $0.0442 | $0.1498 |
| 3 | $0.1299 | $0.0791 | $0.1816 |
| 4 | $0.1901 | $0.1172 | $0.2143 |
| 5 | **$0.2497** | **$0.1648** | **$0.2560** |

**Cumulative totals after 5 turns:**

| Mode | Total tokens | Cache-read tokens | Cost | vs Standard |
|------|-------------:|------------------:|-----:|------------:|
| **Standard** | 72,086 | 50,176 | **$0.250** | baseline |
| **Search** | 46,851 | 32,640 | **$0.165** | **−34%** |
| Code | 73,407 | 55,040 | $0.256 | +2% |

**Search wins the conversation by 34%.** GitHub's catalog is so expensive to re-send
each turn that avoiding it (Search) beats the extra round-trips — the opposite of the
F5 demo (103), where the small catalog meant the re-sent transcript dominated and Search
cost ~4.8× *more*. **Code ties Standard here**: with small per-answer results its
transcript-shrinking advantage is muted, and it still pays a 3,021-token first call
every turn.

---

## 4. Cache analysis (gpt-5.5 prompt caching)

| Mode | Cache-read tokens (5-turn convo) | % of total |
|------|---------------------------------:|-----------:|
| Standard | 50,176 | 70% |
| Search | 32,640 | 70% |
| Code | 55,040 | 75% |

---

## 5. Cache sensitivity — does the Search win survive a different cache rate?

Splits at turn 5 — Standard: uncached 20,436 · cached 50,176 · output 1,474;
Search: uncached 12,994 · cached 32,640 · output 1,217.

| Cache discount | cached $/1K | Standard | Search | Search ÷ Standard |
|----------------|------------:|---------:|-------:|------------------:|
| 50% off (used here) | $0.00250 | $0.250 | $0.165 | **0.66×** |
| 75% off | $0.00125 | $0.187 | $0.124 | 0.66× |
| 90% off | $0.00050 | $0.149 | $0.100 | 0.67× |
| **100% (cache free)** | $0.00000 | $0.124 | $0.083 | **0.67×** |

**Search's conversation win is robust here — ~0.66× at every cache rate.** Unlike the
broad-scope run (where Search only won at typical cache rates), with a single small repo
Search genuinely emits fewer tokens of *every* kind (uncached prompt, cached prompt, and
output), so it wins regardless of the cache discount.

*(Set `IN_PER_1K`/`CACHED_IN_PER_1K`/`OUT_PER_1K` to your contracted rates to recompute.)*

---

## 6. Bottom line & guidance

| Workload | Winner | Why |
|----------|--------|-----|
| Single call, large catalog, modest result | **Search** | −91% per-call context; cheapest on all 5 |
| Long conversation, large catalog | **Search** | catalog tax dominates; −34%, robust to cache rate |
| Multi-step task with *large* per-call results | **Code** | batching + summarize-only repays its overhead only at volume |

**Takeaways**
1. For a verbose catalog like GitHub's, the per-call context reduction is large
   (Search −91%, Code −37%) and **translates to real savings** — Search wins both per
   call and across a conversation when results are modest.
2. **Code is not automatically the winner.** It pays a higher first-call context and
   only overtakes Search when each task returns enough data for batching/summarize-only
   to matter. On a small repo it merely ties Standard.
3. Caching helps every mode (~70–75% served from cache) but does not change the ranking.
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
