# F5 MCP Tool Modes — Test Report

**Demo:** `103-f5-tool-modes`
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
| pools | standard | 1,592 | 4,967 | 2 | $0.0298 | ✅ |
| pools | search | 371 | 2,850 | 3 | $0.0170 | ✅ |
| pools | code | 1,943 | 4,110 | 2 | $0.0217 | ✅ |
| virtuals | standard | 1,586 | 4,538 | 2 | $0.0237 | ✅ |
| virtuals | search | 365 | 8,152 | 5 | $0.0475 | ✅ |
| virtuals | code | 1,937 | 4,148 | 2 | $0.0222 | ✅ |
| system | standard | 1,588 | 3,481 | 2 | $0.0183 | ✅ |
| system | search | 367 | 1,739 | 3 | $0.0114 | ✅ |
| system | code | 1,939 | 6,803 | 3 | $0.0385 | ✅ |
| failover | standard | 1,588 | 3,329 | 2 | $0.0172 | ✅ |
| failover | search | 367 | 1,463 | 3 | $0.0084 | ✅ |
| failover | code | 1,939 | 4,071 | 2 | $0.0210 | ✅ |
| certs | standard | 1,585 | 14,257 | 4 | $0.0747 | ✅ |
| certs | search | 364 | 12,670 | 6 | $0.0709 | ✅ |
| certs | code | 1,936 | 4,144 | 2 | $0.0221 | ✅ |

(Costs are gpt-5.5 list-price estimates; see `harness/f5_questions.py`.)

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
