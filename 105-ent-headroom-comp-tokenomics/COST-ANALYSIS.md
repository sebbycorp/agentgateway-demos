# 105 — Cost & quality matrix (measured)

Measured on a live `agw-headroom-comp` kind cluster, gpt-5.5 list-price, cache-aware.
Single run, 5 questions per cell. `Δ% cost` is the Headroom **saving** (ON vs OFF):
**positive = ON cheaper, negative = ON more expensive.** Raw rows: `harness/results.jsonl`.

## Per-cell averages (5 questions each)

### Small repo — `sebbycorp/agw-tokenomics-sandbox`

| AGW mode | OFF cost $ | ON cost $ | Δ% cost | OFF tok | ON tok | OFF qual /5 | ON qual /5 |
|----------|-----------:|----------:|--------:|--------:|-------:|------------:|-----------:|
| Standard | 0.0289 | 0.0432 | **−49.3%** | 10318 | 12943 | 5.00 | 5.00 |
| Search   | 0.0149 | 0.0138 | +7.3% | 2702 | 2638 | 5.00 | 4.20 |
| Code     | 0.0315 | 0.0204 | +35.4% | 8848 | 6384 | 5.00 | 4.80 |

### Large repo — `sebbycorp/k8s-iceman`

| AGW mode | OFF cost $ | ON cost $ | Δ% cost | OFF tok | ON tok | OFF qual /5 | ON qual /5 |
|----------|-----------:|----------:|--------:|--------:|-------:|------------:|-----------:|
| Standard | 0.0424 | 0.0391 | +7.8% | 13504 | 13355 | 5.00 | 4.20 |
| Search   | 0.0269 | 0.0173 | **+35.8%** | 5148 | 3030 | 4.80 | 4.40 |
| Code     | 0.0623 | 0.0233 | **+62.6%** | 16934 | 7180 | 3.40 | 4.60 |

## First-call tool context (AGW-side, Headroom-independent)

Confirmed from the run: **Standard ~4,780 tok · Search ~428 (−91%) · Code ~3,020 (−37%)** —
exactly the 104 catalog-tax picture. Headroom does not touch this layer.

## Stacking read-out

- **Headroom stacks on top of AGW — but only when payloads are big.** On the large repo it
  adds savings to **every** AGW mode: Code **−63%**, Search **−36%**, Standard −8%.
- **Biggest stacked win:** large repo, **Code + Headroom = $0.0233** (−63% vs Code OFF) and
  **Search + Headroom = $0.0173** (−36%, and the cheapest *reliable* cell overall).
- **Small repo: Headroom does not help and hurts Standard (+49% cost).** Compression rewrites
  the prompt every turn, busting gpt-5.5's prefix cache — which otherwise serves the big stable
  28-tool catalog cheaply. With little result payload to compress, the lost cache > the saving.
- **Quality flag:** the `commits` question repeatedly scored **2/5** under Headroom ON — text
  compression mangles high-entropy **commit SHA hashes**. Cheaper is not free for
  exact-identifier tasks.

## Compatibility caveat (had to be worked around)

Out of the box, Headroom's **semantic cache** and **CCR tool-injection** corrupted the
Search/Code tool-orchestration flow — every Search/Code ON task failed with an MCP TaskGroup
error until the proxy was launched with `--no-cache --no-ccr-inject-tool --no-ccr-marker`. It is
**not** a safe drop-in in front of an MCP tool-calling agent without those flags.

> Single run — treat ±a few points as noise (see demo 104's 3-run variance note). Re-run
> `./run_matrix.sh` 3× for ranges before quoting these as firm.
