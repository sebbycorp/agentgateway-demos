# GitHub MCP Tool Modes — Test Report

**Demo:** `104-ent-github-tokenomics`
**Date:** 2026-06-20
**Backend:** GitHub's **external remote MCP server** (`api.githubcopilot.com/mcp/readonly`)
fronted by AgentGateway; gateway injects the PAT as a Bearer token. **28 read-only tools.**
**LLM:** `gpt-5.5` through the AgentGateway `/openai` route
**Method:** 5 developer questions × 3 tool modes (Standard / Search / Code) = 15 live runs,
plus one ongoing 5-question conversation × 3 modes.

## The 5 questions

1. What is my GitHub login, name, public repos, and follower count?
2. List my 10 most recently updated repositories with their primary language.
3. List the open pull requests I have authored.
4. List open issues assigned to me, with titles and repos.
5. Find my most recently updated repository and show its 5 most recent commits.

Each was asked through all three [tool modes](https://docs.solo.io/agentgateway/latest/mcp/tool-mode/).

## Headline: per-call tool-definition context

The model's first-call tool context (the schemas injected before it does any work):

| Mode | Tools advertised | Avg first-call tokens | vs Standard |
|------|-----------------:|----------------------:|------------:|
| **Standard** | 28 | **4,721** | baseline |
| **Search** | 2 | **369** | **−92%** |
| **Code** | 1 | **2,961** | **−37%** |

GitHub's 28 read-only tools carry **verbose schemas** (~4,721 tokens). Search collapses
them to `get_tool`+`invoke_tool` for a **−92%** per-call context — a bigger win than F5's
−77%. And unlike F5 (where Code's inlined signatures were *larger* than the catalog),
GitHub's catalog is so big that Code's single `run_code` (signatures inlined) is **−37%
smaller** than Standard.

## Full per-question results (gpt-5.5)

| Question | Mode | first-call tok | total tok | cached tok | LLM calls | cost (est) | ok |
|----------|------|---------------:|----------:|-----------:|----------:|-----------:|:--:|
| me       | standard | 4,726 | 9,707   | 4,224   | 2 | $0.0386 | ✅ |
| me       | search   | 374   | 1,609   | 0       | 3 | $0.0092 | ✅ |
| me       | code     | 2,966 | 6,113   | 2,688   | 2 | $0.0248 | ✅ |
| repos    | standard | 4,720 | 23,650  | 18,944  | 4 | $0.0765 | ✅ |
| repos    | search   | 368   | 8,883   | 1,664   | 6 | $0.0497 | ✅ |
| repos    | code     | 2,960 | 6,815   | 2,688   | 2 | $0.0311 | ✅ |
| prs      | standard | 4,716 | 173,759 | 133,248 | 9 | $0.5862 | ✅ |
| prs      | search   | 364   | 65,938  | 33,408  | 10 | $0.2698 | ⚠️ |
| prs      | code     | 2,956 | 14,635  | 9,600   | 3 | $0.0646 | ✅ |
| issues   | standard | 4,720 | 14,744  | 13,184  | 3 | $0.0422 | ✅ |
| issues   | search   | 368   | 6,601   | 1,152   | 6 | $0.0327 | ✅ |
| issues   | code     | 2,960 | 6,524   | 5,376   | 2 | $0.0227 | ✅ |
| commits  | standard | 4,722 | 22,810  | 18,432  | 4 | $0.0745 | ✅ |
| commits  | search   | 370   | 19,724  | 9,600   | 9 | $0.0843 | ✅ |
| commits  | code     | 2,962 | 8,046   | 5,376   | 2 | $0.0371 | ✅ |

**Averages (per task):** Standard $0.1636 · Search $0.0891 · **Code $0.0361**.
(⚠️ `prs/search` hit the 10-call ceiling without finishing — Search thrashed on the
broad PR question. `prs/standard` is a $0.586 outlier: 9 round-trips re-processing
173K tokens. **Code answered every question, cheapest on 4 of 5.**)

## What the data shows (honest read)

- **Code mode is the standout here.** It was cheapest on 4 of 5 single questions, the
  *only* mode that handled the expensive `prs` question cheaply ($0.065 in 3 calls vs
  Standard's $0.586 in 9), and answered all 15 runs. With a big catalog, batching tool
  calls into one `run_code` and returning only summaries pays off twice — small context
  *and* a small transcript.
- **Search's −92% per-call context is real**, and it's cheapest on the simplest question
  (`me`, $0.009). But on broad questions across 196 repos it adds many discovery
  round-trips and once failed to converge (`prs`).
- **Standard pays a steep catalog tax.** 4,721 tokens of tool schema on *every* call,
  and it balloons when a question returns large results it must re-process.

## Multi-turn conversation (the key contrast with the F5 demo)

One ongoing 5-question GitHub chat per mode. History accumulates; the gateway re-sends
tool defs every turn. Cumulative after 5 turns:

| Mode | cum. total tokens | cache-read tokens | cum. cost (cache-aware) | vs Standard |
|------|------------------:|------------------:|------------------------:|------------:|
| **Standard** | 164,711 | 142,848 | **$0.503** | baseline |
| **Search** | 108,410 | 78,592 | **$0.389** | **−23%** |
| **Code** | 39,133 | 31,360 | **$0.139** | **−72%** |

**This is the opposite of demo 103 (F5).** There, Search cost ~4.8× *more* in a long
conversation. Here Search costs **23% less** and Code **72% less**. The deciding
variable is **catalog size**: F5's tool schema was ~1,588 tokens, so re-sending the
accumulated transcript dominated and Standard won. GitHub's is ~4,721 tokens, so the
per-turn catalog tax is large enough that *avoiding* it (Search/Code) beats the
round-trip cost. Code wins biggest because it also keeps the transcript tiny
(39K total tokens vs Standard's 165K — only summaries return, not raw GitHub JSON).

**Bottom line:** with a large, verbose tool catalog like GitHub's, progressive
disclosure pays off in *both* single calls and conversations — and Code mode is the
clear winner. The size of your tool catalog, not a universal rule, decides which mode
saves money. (See `COST-ANALYSIS.md` for the full per-turn + cache breakdown, and demo
103 for the small-catalog case where the answer flips.)

## Reproduce

```bash
cp .env.example .env   # set AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY, GITHUB_PAT
set -a; . .env; set +a
./deploy.sh            # cluster + AGW + OpenAI backend + GitHub external MCP (std/search/code)
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &
kubectl port-forward svc/prometheus-prometheus-pushgateway -n observability 9091:9091 &
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/gh_questions.py     # 5 Qs × 3 modes
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/gh_conversation.py  # 5-turn chat × 3 modes
```
Interactive single questions: `./harness/.venv/bin/python harness/gh_chat.py search "..."`.
