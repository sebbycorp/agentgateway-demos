# F5 MCP Tool Modes — Test Report

**Demo:** `103-agw-tokenomics-with-f5-tool-modes`
**Date:** 2026-06-19
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

| Question | Mode | first-call tok | total tok | LLM calls | cost (est) | ok |
|----------|------|---------------:|----------:|----------:|-----------:|:--:|
| pools | standard | 1,592 | 9,135 | 3 | $0.0507 | ✅ |
| pools | search | 371 | 6,339 | 4 | $0.0390 | ✅ |
| pools | code | 1,943 | 4,143 | 2 | $0.0220 | ✅ |
| virtuals | standard | 1,586 | 4,533 | 2 | $0.0236 | ✅ |
| virtuals | search | 365 | 2,791 | 3 | $0.0165 | ✅ |
| virtuals | code | 1,937 | 4,098 | 2 | $0.0217 | ✅ |
| system | standard | 1,588 | 3,486 | 2 | $0.0184 | ✅ |
| system | search | 367 | 1,583 | 3 | $0.0091 | ✅ |
| system | code | 1,939 | 4,790 | 2 | $0.0282 | ✅ |
| failover | standard | 1,588 | 3,329 | 2 | $0.0172 | ✅ |
| failover | search | 367 | 1,474 | 3 | $0.0086 | ✅ |
| failover | code | 1,939 | 4,081 | 2 | $0.0212 | ✅ |
| certs | standard | 1,585 | 8,555 | 3 | $0.0467 | ✅ |
| certs | search | 364 | 12,617 | 6 | $0.0701 | ✅ |
| certs | code | 1,936 | 4,174 | 2 | $0.0224 | ✅ |

**Averages (per task):** Standard $0.0313 · **Search $0.0286** · Code $0.0231.
Avg first-call tool tokens — Standard 1,588 · **Search 367 (−77%)** · Code 1,939.
(Costs are gpt-5.5 list-price estimates; see `harness/f5_questions.py`. Search/Code
totals vary with how many round-trips the model chooses — e.g. `certs` in Search took
6 turns. First-call tool context is the deterministic, always-smaller win.)

## What the data shows (honest read)

- **Per-call context is the consistent win:** Search keeps first-call tool tokens at
  ~367 regardless of the question — a flat ~77% reduction. This is what shrinks the
  model's context window and the dominant cost in long/agentic sessions.
- **Total task tokens are noisier.** On simple lookups (system, failover) Search is
  cheapest end-to-end. On questions where the model chose many `invoke_tool` round-trips
  (virtuals = 5 calls, certs = 6), Search's total can exceed Standard's because each
  discovery/invoke is a turn. This is the documented trade: progressive disclosure
  trades round-trips for a tiny per-call context.
- **Code mode is steady and batches well:** it answered most questions in 2 calls by
  doing the work in one `run_code` script, giving the lowest *average* cost here — but
  its first-call context is large (all signatures inlined) and it requires a capable
  model to write correct JavaScript (gpt-5.5 handled it; gpt-4o-mini struggled).

**Bottom line:** Search mode cuts the F5 per-call tool context ~77% with no loss of
success — the bigger the tool catalog and the longer the agent runs, the more that
flat, tiny context compounds in your favor.

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
