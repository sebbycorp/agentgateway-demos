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

## Headline: per-call tool-definition context (deterministic)

| Mode | Tools advertised | Avg first-call tokens | vs Standard |
|------|-----------------:|----------------------:|------------:|
| **Standard** | 28 | **4,781** | baseline |
| **Search** | 2 | **429** | **−91%** |
| **Code** | 1 | **3,021** | **−37%** |

GitHub's 28 read-only tools carry verbose schemas (~4,781 tokens). Search collapses
them to `get_tool`+`invoke_tool` for a **−91%** per-call context; Code's single
`run_code` (signatures inlined) is **−37%** smaller than the full catalog. These
numbers are deterministic — they don't vary run to run.

## Full per-question results (gpt-5.5)

| Question | Mode | first-call tok | total tok | cached tok | LLM calls | cost (est) | ok |
|----------|------|---------------:|----------:|-----------:|----------:|-----------:|:--:|
| repo     | standard | 4,784 | 11,097 | 9,472 | 2 | $0.0354 | ✅ |
| repo     | search   | 432   | 3,168  | 0     | 3 | $0.0173 | ✅ |
| repo     | code     | 3,024 | 6,522  | 5,376 | 2 | $0.0220 | ✅ |
| commits  | standard | 4,782 | 10,696 | 9,472 | 2 | $0.0312 | ✅ |
| commits  | search   | 430   | 3,142  | 1,664 | 3 | $0.0132 | ✅ |
| commits  | code     | 3,022 | 6,362  | 5,376 | 2 | $0.0201 | ✅ |
| issues   | standard | 4,779 | 9,951  | 9,472 | 2 | $0.0270 | ✅ |
| issues   | search   | 427   | 2,656  | 0     | 3 | $0.0146 | ✅ |
| issues   | code     | 3,019 | 6,367  | 5,376 | 2 | $0.0201 | ✅ |
| prs      | standard | 4,780 | 9,954  | 9,472 | 2 | $0.0268 | ✅ |
| prs      | search   | 428   | 2,260  | 0     | 3 | $0.0125 | ✅ |
| prs      | code     | 3,020 | 6,234  | 5,376 | 2 | $0.0187 | ✅ |
| contents | standard | 4,780 | 10,101 | 9,472 | 2 | $0.0274 | ✅ |
| contents | search   | 428   | 2,271  | 0     | 3 | $0.0125 | ✅ |
| contents | code     | 3,020 | 6,302  | 5,376 | 2 | $0.0193 | ✅ |

**Averages (per task):** Standard $0.0295 · **Search $0.0140** · Code $0.0200.

## What the data shows (honest read)

- **Search is cheapest on every single question** (~53% under Standard). With one small
  repo there is little result data to re-process, so Search's extra discovery round-trips
  are cheap and its −91% per-call context wins outright.
- **Code beats Standard but not Search here** (~$0.020 avg). Its batching + summarize-only
  advantage needs *data volume* to pay off; a small repo doesn't provide it, so it can't
  overtake Search.
- **Standard pays a flat catalog tax** — 4,781 tokens of tool schema on every call.

## Multi-turn conversation (5 questions deep)

One ongoing 5-question chat per mode against the sandbox repo. Cumulative after 5 turns:

| Mode | cum. total tokens | cache-read tokens | cum. cost (cache-aware) | vs Standard |
|------|------------------:|------------------:|------------------------:|------------:|
| **Standard** | 125,681 | 111,104 | **$0.379** | baseline |
| **Search** | 49,223 | 35,712 | **$0.171** | **−55%** |
| Code | 72,157 | 61,312 | $0.238 | −37% |

**Search wins the conversation decisively (−55%).** GitHub's catalog is so expensive to
re-send each turn that avoiding it (Search) beats the extra round-trips — the opposite of
the F5 demo (103), where the small catalog meant the re-sent transcript dominated and
Search cost ~4.8× *more*. Code also beats Standard here (−37%) but stays above Search.

## Reproducibility & run-to-run variance

This was measured across two live runs. Splitting what is stable from what is noisy:

- **Deterministic (identical every run):** first-call tool context — Standard ~4,781,
  Search ~429 (−91%), Code ~3,021 (−37%); tools advertised (28 / 2 / 1).
- **Stable qualitative findings (both runs):** Search is cheapest on all 5 single
  questions; Search wins the conversation by a wide margin; Standard is the most expensive.
- **Noisy (varies with model nondeterminism + cache warmth):** absolute conversation
  dollars. Across runs we saw Standard **$0.25–$0.38**, Search **$0.16–$0.17** (most
  stable), Code **$0.24–$0.26**. Standard's spread is the largest because the model can
  loop over the big catalog — itself a reason to avoid Standard for a large catalog.

## The contrast with demo 103 (F5)

| | F5 (103), ~1,588-tok catalog | GitHub (104), ~4,781-tok catalog |
|---|---|---|
| Search, single call | ~−18% vs Standard | **~−53%** vs Standard |
| Search, 5-turn convo | **+380% (≈4.8× worse)** | **−55% (better)** |

**Catalog size is the deciding variable.** F5's catalog is small, so the re-sent
transcript dominates and Search loses in conversation. GitHub's catalog is ~3× larger,
so the per-turn catalog tax dominates and Search wins.

**Bottom line:** for a large, verbose catalog like GitHub's, **Search is the clear
money-saver** — per call and across a conversation — when results are modest. Code only
overtakes Search when a single step returns large results. Measure for your catalog *and*
your result sizes.

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
