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
| pools     | $0.02597 | $0.02330 | $0.02204 |
| virtuals  | $0.02358 | $0.01484 | $0.02169 |
| system    | $0.01835 | $0.01162 | $0.03763 |
| failover  | $0.01716 | $0.00852 | $0.02110 |
| certs     | $0.07266 | $0.07097 | $0.02241 |
| **average** | **$0.0315** | **$0.0259** | **$0.0250** |

On single, short questions Search is ~18% cheaper than Standard on average (and up to
~50% on simple lookups like `failover`). Code is steady (it batches tool calls into
one script). The outlier is `certs` — a large result that inflates total tokens in
Standard/Search but not Code (Code returns only the final summary).

---

## 3. Multi-turn conversation cost — one ongoing 5-question chat

History (and every F5 result) accumulates; the gateway re-sends tool defs each turn.

**Cumulative cost per turn:**

| Turn | Standard | Search | Code |
|-----:|---------:|-------:|-----:|
| 1 | $0.0155 | $0.0347 | $0.0493 |
| 2 | $0.0596 | $0.2339 | $0.0781 |
| 3 | $0.0987 | $0.4354 | $0.1398 |
| 4 | $0.1574 | $0.6618 | $0.2290 |
| 5 | **$0.1844** | **$0.7204** | **$0.2528** |

**Cumulative totals after 5 turns:**

| Mode | Total tokens | Cache-read tokens | Cost |
|------|-------------:|------------------:|-----:|
| **Standard** | 51,590 | 36,096 | **$0.184** |
| Code | 67,160 | 49,664 | $0.253 |
| **Search** | 231,414 | 199,680 | **$0.720** |

**The single-call story inverts.** Over a long, tool-heavy conversation **Search is
~4× more expensive than Standard.** Search adds discovery round-trips
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
| Standard | 36,096 | 70% |
| Code | 49,664 | 74% |
| Search | 199,680 | 86% |

Search has the **highest** cache-read share — but that's because it generates the most
re-sent context; caching softens, but does not reverse, its round-trip overhead. The
cost figures above are already cache-aware.

---

## 5. Bottom line & guidance

| Workload | Winner | Why |
|----------|--------|-----|
| Single call / short task, large catalog | **Search / CodeSearch** | ~77% smaller per-call tool context; ~18–50% cheaper |
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
