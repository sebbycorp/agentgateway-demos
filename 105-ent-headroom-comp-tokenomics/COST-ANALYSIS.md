# 105 — Cost & quality matrix

> **🚧 NUMBERS PENDING A LIVE RUN.** The tables below are empty skeletons. Fill them from
> `harness/results.jsonl` + the `run_matrix.sh` console output + the `judge.py` mean-quality
> lines. Do **not** invent values — every number here must come from a measured run on your
> cluster (gpt-5.5 list-price, cache-aware; override the `*_PER_1K` env vars for your rates).

## Method

- Workload: the 5 single-question tasks from demo 104 (`repo`, `commits`, `issues`, `prs`,
  `contents`), run per AGW tool mode.
- Two knobs: AGW `toolMode` ∈ {Standard, Search, Code} × Headroom ∈ {OFF, ON}.
- Two repos: `REPO_SMALL` (104 sandbox) and `REPO_LARGE` (heavy payloads).
- Cost = `(prompt−cached)·IN + cached·CACHED_IN + completion·OUT`, summed over a task's
  round-trips. Quality = `judge.py` 0–5 vs the Standard/OFF answer for the same question.

## Per-cell averages (across the 5 questions)

### Small repo — `REPO_SMALL`

| AGW mode | OFF cost $ | ON cost $ | Δ% (ON vs OFF) | OFF quality /5 | ON quality /5 |
|----------|-----------:|----------:|---------------:|---------------:|--------------:|
| Standard |  _TBD_ | _TBD_ | _TBD_ | _(baseline=5)_ | _TBD_ |
| Search   |  _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |
| Code     |  _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |

### Large repo — `REPO_LARGE`

| AGW mode | OFF cost $ | ON cost $ | Δ% (ON vs OFF) | OFF quality /5 | ON quality /5 |
|----------|-----------:|----------:|---------------:|---------------:|--------------:|
| Standard |  _TBD_ | _TBD_ | _TBD_ | _(baseline=5)_ | _TBD_ |
| Search   |  _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |
| Code     |  _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ |

## First-call tool context (tokens, from AGW — independent of Headroom)

Carried over from 104 as the AGW-side reference: **Standard ~4,781 · Search ~429 (−91%) ·
Code ~3,021 (−37%)**. Confirm in your run.

## Stacking read-out (fill after the run)

- **Does Headroom add savings on top of AGW Search?** small: _TBD_ · large: _TBD_
- **Where is the biggest stacked win?** _TBD_ (hypothesis: Search + ON, large repo)
- **Code + Headroom overlap?** _TBD_ (hypothesis: diminishing — Code already summarizes)
- **Any cell where ON is cheaper but quality drops?** _TBD_ — flag it explicitly.
