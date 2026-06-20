# GitHub MCP Tool Modes — Full Cost Analysis

**Backend:** GitHub's external remote MCP (`api.githubcopilot.com/mcp/readonly`), 28
read-only tools, fronted by AgentGateway (PAT injected as a Bearer token upstream).
**Model:** `gpt-5.5` via the AgentGateway `/openai` route
**Pricing (list-price estimate, USD / 1K tokens):** input `$0.005`, cached input
`$0.0025` (≈50% off), output `$0.015`
**Modes:** Standard (28 tools) · Search (`get_tool`+`invoke_tool`) · Code (`run_code`)
**Runs:** single-call (5 questions × 3 modes) + one ongoing 5-question conversation × 3 modes.

---

## 1. Per-call tool context (the structural difference)

Deterministic — the tool schema the gateway injects on the **first** call:

| Mode | Tools advertised | First-call tool tokens | vs Standard |
|------|-----------------:|-----------------------:|------------:|
| **Standard** | 28 | 4,721 | — |
| **Search** | 2 | **369** | **−92%** |
| **Code** | 1 | 2,961 | **−37%** |

GitHub's read-only tools have **verbose schemas** — 4,721 tokens for the catalog. That
makes the per-call context a much bigger lever than in the F5 demo (1,588 tokens).
Search's −92% and Code's −37% are both larger reductions than F5's.

---

## 2. Single-call cost — one question, fresh session

| Question | Standard | Search | Code |
|----------|---------:|-------:|-----:|
| me        | $0.03861 | $0.00915 | $0.02482 |
| repos     | $0.07653 | $0.04974 | $0.03114 |
| prs       | $0.58624 | $0.26976 ⚠️ | $0.06462 |
| issues    | $0.04218 | $0.03271 | $0.02272 |
| commits   | $0.07445 | $0.08433 | $0.03705 |
| **average** | **$0.1636** | **$0.0891** | **$0.0361** |

**Code is cheapest on 4 of 5 questions** and the only mode that handled `prs` cheaply.
The `prs` row is the story: across 196 repos the model had to fan out. Standard looped
9 times re-processing 173K tokens ($0.586); Search hit the 10-call ceiling **without
finishing** (⚠️); Code did it in one `run_code` (3 calls, $0.065). Search wins only on
the trivial `me` lookup.

---

## 3. Multi-turn conversation cost — one ongoing 5-question chat

History (and every GitHub result) accumulates; the gateway re-sends tool defs each turn.

**Cumulative cost per turn:**

| Turn | Standard | Search | Code |
|-----:|---------:|-------:|-----:|
| 1 | $0.0279 | $0.0091 | $0.0178 |
| 2 | $0.0616 | $0.0306 | $0.0436 |
| 3 | $0.2231 | $0.1534 | $0.0772 |
| 4 | $0.4494 | $0.3472 | $0.1175 |
| 5 | **$0.5033** | **$0.3888** | **$0.1387** |

**Cumulative totals after 5 turns:**

| Mode | Total tokens | Cache-read tokens | Cost | vs Standard |
|------|-------------:|------------------:|-----:|------------:|
| **Standard** | 164,711 | 142,848 | **$0.503** | baseline |
| **Search** | 108,410 | 78,592 | **$0.389** | **−23%** |
| **Code** | 39,133 | 31,360 | **$0.139** | **−72%** |

**This inverts the F5 result.** In demo 103 (F5, ~1,588-token catalog) Search cost
~4.8× *more* over a conversation. Here, with GitHub's ~4,721-token catalog, Search is
**23% cheaper** and Code **72% cheaper** than Standard. The catalog is now so expensive
to re-send every turn that avoiding it (Search/Code) outweighs the extra round-trips.
Code also keeps the transcript tiny — only summaries return, so its total token count
(39K) is **4.2× smaller** than Standard's (165K).

---

## 4. Cache analysis (gpt-5.5 prompt caching)

| Mode | Cache-read tokens (5-turn convo) | % of total |
|------|---------------------------------:|-----------:|
| Standard | 142,848 | 87% |
| Search | 78,592 | 72% |
| Code | 31,360 | 80% |

Standard has the **highest** cache share — its giant catalog is re-sent every turn and
served cheap from cache. That matters for the next section.

---

## 5. Cache sensitivity — does the Search win survive a different cache rate?

The headline uses a **50%-off** cached rate. Recomputing the 5-turn cost from the actual
captured token splits across the cache-discount range:

Splits at turn 5 — Standard: uncached 18,174 · cached 142,848 · output 3,689;
Search: uncached 25,494 · cached 78,592 · output 4,324;
Code: uncached 5,635 · cached 31,360 · output 2,138.

| Cache discount | cached $/1K | Standard | Search | Code | Search ÷ Standard |
|----------------|------------:|---------:|-------:|-----:|------------------:|
| 50% off (used here) | $0.00250 | $0.503 | $0.389 | $0.139 | **0.77×** |
| 75% off | $0.00125 | $0.325 | $0.291 | $0.099 | 0.90× |
| 90% off | $0.00050 | $0.218 | $0.232 | $0.076 | 1.06× |
| **100% (cache free)** | $0.00000 | $0.146 | $0.192 | $0.060 | **1.32×** |

**Two honest conclusions:**

1. **Code wins at every cache rate** — decisively ($0.060–$0.139, always far below the
   others). Its advantage isn't a caching artifact; it simply produces ~4× fewer tokens.
2. **Search's conversation win over Standard *depends on caching*.** At the realistic
   ~50%-off rate Search is 23% cheaper, but if cached tokens were nearly free, Standard's
   enormous-but-cached catalog becomes almost free and Standard wins (Search has more
   *uncached* prompt and more output). So "Search beats Standard in a GitHub conversation"
   is true at typical cache rates but not guaranteed — measure with your provider's rate.

*(Set `IN_PER_1K`/`CACHED_IN_PER_1K`/`OUT_PER_1K` to your contracted rates to recompute.)*

---

## 6. Bottom line & guidance

| Workload | Winner | Why |
|----------|--------|-----|
| Single call / short task | **Code** (Search for trivial lookups) | −37% context + batching; cheapest on 4/5 |
| Broad question over many repos | **Code** | one `run_code` vs Standard's 9-call thrash / Search's non-convergence |
| Long agentic conversation | **Code**, then Search | huge catalog tax makes progressive disclosure pay off both ways |

**Takeaways**
1. The per-call tool-context reduction is large for a verbose catalog like GitHub's
   (Search −92%, Code −37%).
2. Unlike the small-catalog F5 case, here it **does** translate to lower total cost —
   in both single calls and conversations — because the catalog is expensive to re-send.
3. **Code mode is the clear overall winner** for GitHub: smallest context *and* smallest
   transcript (only summaries return), cheapest at every cache rate.
4. **Catalog size is the deciding variable.** Compare with demo 103 (F5): same three
   modes, opposite conversation verdict. Measure for *your* catalog and conversation depth.

## Reproduce

```bash
set -a; . .env; set +a            # gpt-5.5 backend; AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY, GITHUB_PAT
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &
kubectl port-forward svc/prometheus-prometheus-pushgateway -n observability 9091:9091 &
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/gh_questions.py      # single-call
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/gh_conversation.py   # multi-turn
```
Dashboard: `kubectl port-forward svc/grafana -n observability 3001:80` → **GitHub — MCP Tool Modes**.
