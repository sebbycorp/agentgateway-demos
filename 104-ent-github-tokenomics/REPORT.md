# GitHub MCP Tool Modes — Test Report

**Demo:** `104-ent-github-tokenomics`
**Date:** 2026-06-20
**Backend:** GitHub's **external remote MCP server** (`api.githubcopilot.com/mcp/readonly`)
fronted by AgentGateway; gateway injects the PAT as a Bearer token. **28 read-only tools.**
**Scope:** every question is pinned to **one dedicated public sandbox repo** —
[`sebbycorp/agw-tokenomics-sandbox`](https://github.com/sebbycorp/agw-tokenomics-sandbox).
A read-only system instruction plus a fine-grained, single-repo PAT (see README) mean
the test cannot touch any other repository.
**LLM:** `gpt-5.5` through the AgentGateway `/openai` route
**Method:** 5 questions × 3 tool modes (Standard / Search / Code) = 15 live runs, plus
one ongoing 5-question conversation × 3 modes. **All runs succeeded (100%).**

## The 5 questions (all against the sandbox repo)

1. Describe the repo: description, default branch, primary language.
2. List the 5 most recent commits with their messages.
3. List the open issues with their titles.
4. List the open pull requests with their titles.
5. List the files in the `src/` directory.

## Headline: per-call tool-definition context

| Mode | Tools advertised | Avg first-call tokens | vs Standard |
|------|-----------------:|----------------------:|------------:|
| **Standard** | 28 | **4,781** | baseline |
| **Search** | 2 | **429** | **−91%** |
| **Code** | 1 | **3,021** | **−37%** |

GitHub's 28 read-only tools carry verbose schemas (~4,781 tokens). Search collapses
them to `get_tool`+`invoke_tool` for a **−91%** per-call context; Code's single
`run_code` (signatures inlined) is **−37%** smaller than the full catalog.

## Full per-question results (gpt-5.5)

| Question | Mode | first-call tok | total tok | cached tok | LLM calls | cost (est) | ok |
|----------|------|---------------:|----------:|-----------:|----------:|-----------:|:--:|
| repo     | standard | 4,784 | 10,988 | 4,736 | 2 | $0.0456 | ✅ |
| repo     | search   | 432   | 3,214  | 0     | 3 | $0.0179 | ✅ |
| repo     | code     | 3,024 | 19,144 | 9,088 | 5 | $0.0834 | ✅ |
| commits  | standard | 4,782 | 10,675 | 4,736 | 2 | $0.0427 | ✅ |
| commits  | search   | 430   | 3,141  | 0     | 3 | $0.0173 | ✅ |
| commits  | code     | 3,022 | 6,359  | 5,376 | 2 | $0.0200 | ✅ |
| issues   | standard | 4,779 | 9,953  | 4,736 | 2 | $0.0389 | ✅ |
| issues   | search   | 427   | 2,651  | 0     | 3 | $0.0145 | ✅ |
| issues   | code     | 3,019 | 6,319  | 2,688 | 2 | $0.0263 | ✅ |
| prs      | standard | 4,780 | 9,954  | 4,736 | 2 | $0.0386 | ✅ |
| prs      | search   | 428   | 2,261  | 0     | 3 | $0.0125 | ✅ |
| prs      | code     | 3,020 | 6,234  | 5,376 | 2 | $0.0187 | ✅ |
| contents | standard | 4,780 | 10,101 | 4,736 | 2 | $0.0392 | ✅ |
| contents | search   | 428   | 2,286  | 0     | 3 | $0.0127 | ✅ |
| contents | code     | 3,020 | 6,302  | 5,376 | 2 | $0.0193 | ✅ |

**Averages (per task):** Standard $0.0410 · **Search $0.0150** · Code $0.0335.

## What the data shows (honest read)

- **Search is cheapest on every single question** — about **63% under Standard** on
  average. With a single small repo there is little result data to re-process, so
  Search's extra discovery round-trips are cheap and its −91% per-call context wins
  outright.
- **Code is mid-pack here, with one outlier.** On `repo` the model wrote a `run_code`
  that fanned out over 5 calls ($0.083); on the other four it was steady (~$0.02).
  Code's batching + summarize-only advantage needs *data volume* to pay off — on a
  small repo its larger first-call context and JS overhead aren't repaid.
- **Standard pays a flat catalog tax** — 4,781 tokens of tool schema on every call.

## Multi-turn conversation (5 questions deep)

One ongoing 5-question chat per mode against the sandbox repo. Cumulative after 5 turns:

| Mode | cum. total tokens | cache-read tokens | cum. cost (cache-aware) | vs Standard |
|------|------------------:|------------------:|------------------------:|------------:|
| **Standard** | 72,086 | 50,176 | **$0.250** | baseline |
| **Search** | 46,851 | 32,640 | **$0.165** | **−34%** |
| Code | 73,407 | 55,040 | $0.256 | +2% |

**Search wins the conversation too (−34%)**, and unlike the broad-scope run this win is
robust across cache rates (Search has fewer tokens of *every* kind here). **Code lands
level with Standard** — its transcript-shrinking trick doesn't help when each answer is
already small, and it pays the higher first-call context every turn.

## The contrast with demo 103 (F5)

Same three modes, opposite conversation verdict from F5:

| | F5 (103), ~1,588-tok catalog | GitHub (104), ~4,781-tok catalog |
|---|---|---|
| Search, single call | −18% vs Standard | **−63%** vs Standard |
| Search, 5-turn convo | **+380% (≈4.8× worse)** | **−34% (better)** |

**Catalog size is the deciding variable.** F5's catalog is small, so in a conversation
the re-sent transcript dominates and Search's extra round-trips lose. GitHub's catalog
is ~3× larger, so the per-turn catalog tax dominates and avoiding it (Search) wins.

**Bottom line:** for a large, verbose catalog like GitHub's, **Search is the clear
money-saver** — both per call and across a conversation — when individual results are
modest in size. Code only overtakes Search when there's enough per-task data for its
batching/summarize-only behavior to repay its overhead (see the broad-scope numbers in
demo history). Measure for your catalog *and* your result sizes.

## Reproduce

```bash
cp .env.example .env   # set AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY, GITHUB_PAT (read-only, single-repo)
set -a; . .env; set +a
./deploy.sh            # cluster + AGW + OpenAI backend + GitHub external MCP (std/search/code)
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &
kubectl port-forward svc/prometheus-prometheus-pushgateway -n observability 9091:9091 &
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/gh_questions.py     # 5 Qs × 3 modes
LLM_NO_TEMPERATURE=1 ./harness/.venv/bin/python harness/gh_conversation.py  # 5-turn chat × 3 modes
```
Point at a different repo with `GH_REPO=owner/name`. Interactive:
`./harness/.venv/bin/python harness/gh_chat.py search "list the open issues"`.
