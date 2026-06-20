# F5 MCP Tool Modes — Test Report

**Demo:** `103-agw-tokenomics-with-f5-tool-modes`
**Date:** 2026-06-20
**Backend:** real F5 BIG-IP (`172.16.10.10`) via the `f5-wrapper` MCP server (29 LTM tools), READ_ONLY
**LLM:** `gpt-5.5` through the AgentGateway `/openai` route
**Method:** 5 operator questions × 3 tool modes (Standard / Search / Code) = 15 live runs

## The 5 questions

1. How many LTM pools are in the Common partition, and list their names?
2. List the LTM virtual servers and their destinations.
3. What is the BIG-IP version, hostname, and platform?
4. What is the HA failover status?
5. List the SSL certificates and their expiration dates.

Each was asked through all three [tool modes](https://docs.solo.io/agentgateway/latest/mcp/tool-mode/);
**all 15 runs answered successfully (100%).**

## Headline: per-call tool-definition context

The model's first-call tool context (the schemas injected before it does any work):

| Mode | Tools advertised | Avg first-call tokens | vs Standard |
|------|-----------------:|----------------------:|------------|
| **Standard** | 29 | **1,588** | baseline |
| **Search** | 2 | **367** | **−77%** |
| **Code** | 1 | 1,938 | +22% |

Search mode replaces the 29-tool F5 catalog with `get_tool` + `invoke_tool`, cutting
the per-call tool context **~77%**. Code mode exposes a single `run_code` tool, but
its description **inlines the typed JS signature of every F5 tool**, so its first-call
context is *not* smaller — Code mode's value is workflow batching, not context size.

## Full per-question results (gpt-5.5)

| Question | Mode | first-call tok | total tok | cached tok | LLM calls | cost (est) | ok |
|----------|------|---------------:|----------:|-----------:|----------:|-----------:|:--:|
| pools | standard | 1,592 | 9,465 | 3,840 | 3 | $0.0461 | ✅ |
| pools | search | 371 | 7,135 | 4,352 | 4 | $0.0401 | ✅ |
| pools | code | 1,943 | 4,114 | 3,328 | 2 | $0.0134 | ✅ |
| virtuals | standard | 1,586 | 4,591 | 2,688 | 2 | $0.0178 | ✅ |
| virtuals | search | 365 | 2,722 | 0 | 3 | $0.0154 | ✅ |
| virtuals | code | 1,937 | 4,088 | 3,328 | 2 | $0.0132 | ✅ |
| system | standard | 1,588 | 3,484 | 2,304 | 2 | $0.0126 | ✅ |
| system | search | 367 | 1,694 | 0 | 3 | $0.0108 | ✅ |
| system | code | 1,939 | 4,678 | 1,664 | 2 | $0.0229 | ✅ |
| failover | standard | 1,588 | 3,329 | 0 | 2 | $0.0172 | ✅ |
| failover | search | 367 | 1,465 | 0 | 3 | $0.0084 | ✅ |
| failover | code | 1,939 | 4,071 | 3,328 | 2 | $0.0127 | ✅ |
| certs | standard | 1,585 | 14,246 | 9,216 | 4 | $0.0516 | ✅ |
| certs | search | 364 | 12,705 | 4,864 | 6 | $0.0593 | ✅ |
| certs | code | 1,936 | 4,122 | 3,328 | 2 | $0.0135 | ✅ |

**Averages (per task):** Standard $0.0290 · **Search $0.0268** · **Code $0.0151**.
Avg first-call tool tokens — Standard 1,588 · **Search 367 (−77%)** · Code 1,939.
(Costs are gpt-5.5 list-price, cache-aware estimates; see `harness/f5_questions.py`.
Search/Code totals vary with how many round-trips the model chooses — e.g. `certs` in
Search took 6 turns. First-call tool context is the deterministic, always-smaller win;
Code was cheapest end-to-end here by batching calls and returning only the summary.)

## What the data shows (honest read)

- **Per-call context is the consistent win:** Search keeps first-call tool tokens at
  ~367 regardless of the question — a flat ~77% reduction. This is what shrinks the
  model's context window and the dominant cost in long/agentic sessions.
- **Total task tokens are noisier.** On simple lookups (system, failover) Search is
  cheapest end-to-end. On questions where the model chose many `invoke_tool` round-trips
  (certs = 6 calls), Search's total can exceed Standard's because each discovery/invoke
  is a turn. This is the documented trade: progressive disclosure trades round-trips for
  a tiny per-call context.
- **Code mode is steady and batches well:** it answered every question in 2 calls by
  doing the work in one `run_code` script and returning only the summary, giving the
  lowest *average* cost here ($0.0151, ~48% under Standard) — but its first-call context
  is large (all signatures inlined) and it requires a capable model to write correct
  JavaScript (gpt-5.5 handled it; gpt-4o-mini struggled).

**Bottom line:** Search mode cuts the F5 per-call tool context ~77% with no loss of
success — the bigger the tool catalog and the longer the agent runs, the more that
flat, tiny context compounds in your favor.

## Multi-turn conversation (3–5 questions deep) — the important nuance

The numbers above are single questions. A real operator has a *conversation*. We ran
one ongoing 5-question F5 chat per mode (`harness/f5_conversation.py`), where the
message history (including every F5 result) accumulates and the gateway re-sends the
tool definitions on every turn. gpt-5.5 prompt caching is captured (cache reads).

**Cumulative after 5 turns:**

| Mode | cum. total tokens | cache-read tokens | cum. cost (cache-aware) |
|------|------------------:|------------------:|------------------------:|
| **Standard** | 51,640 | 31,360 | **$0.197** |
| Code | 68,454 | 52,736 | $0.247 |
| **Search** | 286,075 | 226,816 | **$0.943** |

**This flips the single-call story — and it's the key insight.** In a long,
tool-heavy conversation **Search costs *more*, not less.** Why: Search adds discovery
round-trips (`get_tool` → `invoke_tool`, often several per question), and **every
extra round-trip re-sends the entire accumulated conversation history** (full of F5
JSON). The per-call tool-definition saving (367 vs 1,588) is real but small next to
re-processing a growing transcript many times. Standard pays a fixed 29-tool catalog
tax per turn but takes fewer round-trips. Code batches tool calls into one `run_code`
and lands in between. Prompt caching is heavy in every mode (gpt-5.5 served
31k–227k tokens from cache) but does not reverse Search's round-trip overhead.

**Rule of thumb:**
- **Large catalog + short task / single call →** Search/CodeSearch: ~77% smaller tool
  context, cheaper.
- **Long agentic conversation with many tool results →** weigh the round-trips; the
  flat per-call context win can be outweighed by re-sent history. Standard or Code may
  win on total cost.

The demo lets you *measure* this for your own workload rather than assume it.

## Dashboard

Provisioned Grafana dashboard **"F5 BIG-IP — MCP Tool Modes"** (uid `agw-f5-tool-modes`)
visualizes all of the above: first-call tokens by mode, tool-context reduction %,
tools advertised per mode, total tokens & cost per question, and task success.

```bash
kubectl port-forward svc/grafana -n observability 3001:80   # http://localhost:3001 (admin/admin)
```

## Reproduce

```bash
cp .env.example .env   # set AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY, F5_PASSWORD
set -a; . .env; set +a
./deploy.sh            # cluster + AGW + OpenAI backend + F5 (std/search/code)
# point the /openai backend at gpt-5.5 for clean Code-mode runs, then:
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &
kubectl port-forward svc/prometheus-prometheus-pushgateway -n observability 9091:9091 &
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/f5_questions.py   # runs the 5 Qs × 3 modes
```
Interactive single questions: `./harness/.venv/bin/python harness/f5_chat.py search "..."`.
