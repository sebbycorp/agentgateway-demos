# F5 MCP Tool Modes — Full Cost Analysis

**Backend:** real F5 BIG-IP (`172.16.10.10`), `f5-wrapper` MCP server, 29 LTM tools, READ_ONLY
**Model:** `gpt-5.5` via the AgentGateway `/openai` route
**Pricing (list-price estimate, USD / 1K tokens):** input `$0.005`, cached input `$0.0025` (≈50% off), output `$0.015`
**Modes:** Standard (29 tools) · Search (`get_tool`+`invoke_tool`) · Code (`run_code`)
**Runs:** single-call (5 questions × 3 modes) + one ongoing 5-question conversation × 3 modes. All runs succeeded.

---

## 1. Per-call tool context (the structural difference)

This is deterministic — it's the tool schema the gateway injects on the **first** call:

| Mode | Tools advertised | First-call tool tokens | vs Standard |
|------|-----------------:|-----------------------:|------------:|
| **Standard** | 29 | 1,588 | — |
| **Search** | 2 | **367** | **−77%** |
| **Code** | 1 | 1,939 | +22% |

Search collapses the 29-tool catalog into 2 meta-tools → 77% smaller per-call tool
context. Code exposes one `run_code` tool but inlines every tool's JS signature into
its description, so its first-call context is the largest.

---

## 2. Single-call cost — one question, fresh session

| Question | Standard | Search | Code |
|----------|---------:|-------:|-----:|
| pools     | $0.04607 | $0.04005 | $0.01340 |
| virtuals  | $0.01779 | $0.01544 | $0.01317 |
| system    | $0.01256 | $0.01075 | $0.02294 |
| failover  | $0.01716 | $0.00844 | $0.01269 |
| certs     | $0.05163 | $0.05926 | $0.01351 |
| **average** | **$0.0290** | **$0.0268** | **$0.0151** |

On single, short questions Search is ~8% cheaper than Standard on average (and up to
~50% on simple lookups like `failover`). **Code is cheapest here ($0.0151, ~48% under
Standard)** — it batches tool calls into one script and returns only the final summary,
so a large result like `certs` (which inflates total tokens in Standard/Search) stays
in the sandbox and never bloats the model's context.

---

## 3. Multi-turn conversation cost — one ongoing 5-question chat

History (and every F5 result) accumulates; the gateway re-sends tool defs each turn.

**Cumulative cost per turn:**

| Turn | Standard | Search | Code |
|-----:|---------:|-------:|-----:|
| 1 | $0.0184 | $0.0472 | $0.0377 |
| 2 | $0.0637 | $0.3092 | $0.0910 |
| 3 | $0.1033 | $0.5103 | $0.1399 |
| 4 | $0.1725 | $0.8326 | $0.2214 |
| 5 | **$0.1975** | **$0.9426** | **$0.2473** |

**Cumulative totals after 5 turns:**

| Mode | Total tokens | Cache-read tokens | Cost |
|------|-------------:|------------------:|-----:|
| **Standard** | 51,640 | 31,360 | **$0.197** |
| Code | 68,454 | 52,736 | $0.247 |
| **Search** | 286,075 | 226,816 | **$0.943** |

**The single-call story inverts.** Over a long, tool-heavy conversation **Search is
~4.8× more expensive than Standard.** Search adds discovery round-trips
(`get_tool`→`invoke_tool`, several per question) and **every extra round-trip
re-sends the entire growing transcript** (full of F5 JSON). The flat per-call
tool-context saving (367 vs 1,588) is swamped by re-processing accumulated history.
Standard pays a fixed catalog tax per turn but takes the fewest round-trips. Code
batches calls into one `run_code` and lands in the middle.

---

## 4. Cache analysis (gpt-5.5 prompt caching)

Caching is real and substantial in every mode — the stable prefix (system + tools +
earlier turns) is served at the cached rate (~50% off):

| Mode | Cache-read tokens (5-turn convo) | % of total |
|------|---------------------------------:|-----------:|
| Standard | 31,360 | 61% |
| Code | 52,736 | 77% |
| Search | 226,816 | 79% |

Search has the **highest** cache-read share — but that's because it generates the most
re-sent context; caching softens, but does not reverse, its round-trip overhead. The
cost figures above are already cache-aware.

### When does caching actually apply?

Caching is on the **input/prompt only** (output/completion is never cached). The
provider caches the longest **stable prefix** it has seen recently and bills it at the
cached rate; only the new suffix pays full price. Conditions: the repeated prefix must
be **≥ ~1,024 tokens**, reused within the **~5–10 min TTL**, and match exactly from the
start. A request is `[tools block] + [conversation so far] + [new message]` — the first
two parts are stable, so caching kicks in **from the 2nd LLM call onward** (within one
agentic task *and* across conversation turns).

| Mode | What's cacheable | Cold first call |
|------|------------------|-----------------|
| Standard | 29-tool block (~1,588 tok) is itself > 1,024 → caches on its own | tool block cached from call 2 |
| Search | 2 meta-tools (~367 tok) are **below the 1,024 floor** → only the accumulated **history** caches | **no cache** on a short first call (we saw `cached=0` on single-call Search) |
| Code | `run_code` description (~1,900 tok) > 1,024 → caches like Standard, plus history | description cached from call 2 |

This is why single-call Search often shows **0 cached tokens** (nothing big enough to
cache yet), while in a long conversation Search caches the most (its re-sent history).

## 5. Cache sensitivity — does cheaper/free cache change the verdict?

The headline cost uses a **50%-off** cached rate (an estimate). Because that rate is the
biggest assumption, here is the 5-turn conversation cost recomputed from the **actual
captured token splits** across the full range of cache discounts:

Splits at turn 5 — Standard: uncached 18,512 · cached 31,360 · output 1,768;
Search: uncached 51,329 · cached 226,816 · output 7,930.

| Cache discount | cached $/1K | Standard | Search | Search ÷ Standard |
|----------------|------------:|---------:|-------:|------------------:|
| 50% off (used in this report) | $0.00250 | $0.197 | $0.943 | 4.8× |
| 75% off | $0.00125 | $0.158 | $0.659 | 4.2× |
| 90% off | $0.00050 | $0.135 | $0.489 | 3.6× |
| **100% (cache free)** | $0.00000 | $0.119 | $0.376 | **3.2×** |

**Even if cached tokens were free, Search still costs ~3.2× more here.** Two reasons
caching can't close the gap: (1) **output tokens are never cached** and Search emits
~4.5× more of them (7,930 vs 1,768) from its extra round-trips; (2) Search also has more
**uncached** prompt tokens (51,329 vs 18,512). Standard's "always send the tools" cost is
itself mostly cached, so both sides benefit — Search just produces far more total
throughput, and more of the un-cacheable kind.

*(Pricing is gpt-5.5 list-price estimate. Set `IN_PER_1K`/`CACHED_IN_PER_1K`/`OUT_PER_1K`
to your contracted rates to recompute; the ratios above show the conclusion is robust
across the whole cache-discount range.)*

---

## 6. Bottom line & guidance

| Workload | Winner | Why |
|----------|--------|-----|
| Single call / short task, large catalog | **Search / Code** | ~77% smaller per-call tool context (Search); ~8–50% cheaper, Code lowest (~48% under Standard) |
| Long agentic conversation, many tool results | **Standard or Code** | Search's extra round-trips re-send the growing transcript |
| Multi-step workflow over many tools | **Code** | one `run_code` batches calls; only the final result returns |

**Takeaways**
1. The per-call tool-context reduction from Search is real and structural (−77%).
2. It does **not** automatically translate to lower *total* cost — round-trip count
   and conversation length dominate once a transcript accumulates.
3. Caching helps all modes (~70–86% of prompt served from cache here) but doesn't
   change the ranking.
4. **Measure for your workload.** This demo (`f5_questions.py` single-call,
   `f5_conversation.py` multi-turn) lets you put real numbers on your own F5 tasks and
   conversation depth rather than assume a mode "saves money."

## Reproduce

```bash
set -a; . .env; set +a            # gpt-5.5 backend; AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY, F5_PASSWORD
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &
kubectl port-forward svc/prometheus-prometheus-pushgateway -n observability 9091:9091 &
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/f5_questions.py      # single-call
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/f5_conversation.py   # multi-turn
```
Dashboard: `kubectl port-forward svc/grafana -n observability 3001:80` → **F5 BIG-IP — MCP Tool Modes**.
