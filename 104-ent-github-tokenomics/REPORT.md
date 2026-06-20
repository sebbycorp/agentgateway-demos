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
**Method:** 5 questions × 3 tool modes = 15 single-call runs, plus one 5-question
conversation × 3 modes. Run **three times** to separate signal from noise. All runs succeeded.

## The 5 questions (all against the sandbox repo)

1. Describe the repo: description, default branch, primary language.
2. List the 5 most recent commits with their messages.
3. List the open issues with their titles.
4. List the open pull requests with their titles.
5. List the files in the `src/` directory.

## Headline: per-call tool-definition context (deterministic — identical every run)

| Mode | Tools advertised | Avg first-call tokens | vs Standard |
|------|-----------------:|----------------------:|------------:|
| **Standard** | 28 | **4,781** | baseline |
| **Search** | 2 | **429** | **−91%** |
| **Code** | 1 | **3,021** | **−37%** |

## Full per-question results (latest run, gpt-5.5)

| Question | Mode | first-call tok | total tok | cached tok | LLM calls | cost (est) | ok |
|----------|------|---------------:|----------:|-----------:|----------:|-----------:|:--:|
| repo     | standard | 4,784 | 10,896 | 9,472 | 2 | $0.0324 | ✅ |
| repo     | search   | 432   | 3,193  | 1,664 | 3 | $0.0135 | ✅ |
| repo     | code     | 3,024 | 6,631  | 5,376 | 2 | $0.0233 | ✅ |
| commits  | standard | 4,782 | 10,700 | 9,472 | 2 | $0.0313 | ✅ |
| commits  | search   | 430   | 3,136  | 0     | 3 | $0.0173 | ✅ |
| commits  | code     | 3,022 | 6,372  | 5,376 | 2 | $0.0202 | ✅ |
| issues   | standard | 4,779 | 9,955  | 9,472 | 2 | $0.0271 | ✅ |
| issues   | search   | 427   | 2,653  | 0     | 3 | $0.0145 | ✅ |
| issues   | code     | 3,019 | 6,347  | 5,376 | 2 | $0.0199 | ✅ |
| prs      | standard | 4,780 | 9,956  | 4,736 | 2 | $0.0386 | ✅ |
| prs      | search   | 428   | 1,285  | 0     | 2 | $0.0074 | ✅ |
| prs      | code     | 3,020 | 6,234  | 5,376 | 2 | $0.0187 | ✅ |
| contents | standard | 4,780 | 10,101 | 4,736 | 2 | $0.0392 | ✅ |
| contents | search   | 428   | 2,267  | 0     | 3 | $0.0125 | ✅ |
| contents | code     | 3,020 | 6,282  | 5,376 | 2 | $0.0191 | ✅ |

**Single-call averages (per task):** Standard $0.0337 · **Search $0.0130** · Code $0.0202.
**Search is cheapest on all 5 questions — in every one of the three runs** (~61% under
Standard this run; 53–68% across runs).

## Multi-turn conversation — 3 runs (the honest picture)

One ongoing 5-question chat per mode. Cumulative cost after 5 turns, each run:

| Run | Standard | Search | Code |
|----:|---------:|-------:|-----:|
| 1 | $0.250 | $0.165 | $0.256 |
| 2 | $0.379 | $0.171 | $0.238 |
| 3 | $0.233 | $0.175 | $0.159 |
| **range** | **$0.233–0.379** | **$0.165–0.175** | **$0.159–0.256** |

**What's stable:** Both **Search and Code beat Standard** in every run (Code essentially
tied it in run 1). **Search is the most predictable** — a tight ~$0.17 every time.
Standard is the most expensive *and* the noisiest, because the model sometimes loops over
the 28-tool catalog. **What's noisy:** which of Search/Code is cheapest flips run-to-run
(Search in runs 1–2, Code in run 3), and Standard's absolute cost swings ~60%.

## What the data shows (honest read)

- **Single call → Search, decisively.** Cheapest on all 5 questions, all 3 runs. With one
  small repo there's little result data, so its extra discovery round-trips are cheap and
  the −91% per-call context wins outright.
- **Conversation → Search or Code, never Standard.** GitHub's catalog is expensive to
  re-send each turn, so avoiding it (both Search and Code) beats paying the catalog tax.
  Search is the safe, stable pick; Code can edge ahead when it batches well.
- **Standard pays — and is unpredictable.** A flat 4,781-token catalog tax every call,
  and it can balloon when the model loops.

## The contrast with demo 103 (F5)

| | F5 (103), ~1,588-tok catalog | GitHub (104), ~4,781-tok catalog |
|---|---|---|
| Search, single call | ~−18% vs Standard | **~−60%** vs Standard |
| Search, 5-turn convo | **+380% (≈4.8× worse)** | **−25% to −55% (better)** |

**Catalog size is the deciding variable.** F5's catalog is small, so the re-sent transcript
dominates and Search loses in conversation. GitHub's is ~3× larger, so the per-turn catalog
tax dominates and Search wins.

**Bottom line:** for a large, verbose catalog like GitHub's, **avoid Standard** — Search is
the cheapest, most predictable choice (single calls and conversations), and Code is a strong
alternative that pulls ahead when individual results are large. Measure for your catalog
*and* your result sizes.

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
