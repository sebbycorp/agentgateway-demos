# 105 — Report: do AgentGateway tool modes and Headroom stack?

Measured on a live `agw-headroom-comp` kind cluster (Enterprise AGW v2026.6.1, gpt-5.5),
fronting GitHub's external MCP. 12 cells = 3 AGW tool modes × Headroom OFF/ON × 2 repos,
5 questions each + an LLM-judge quality score. Full table: [`COST-ANALYSIS.md`](./COST-ANALYSIS.md).

## The question

AGW tool modes (104) shrink the **tool-catalog tax**. Headroom shrinks the **content payload**.
Different layers — so do the savings **stack**?

## Verdict: yes, but only when there's payload to compress — and not for free

**1. On a large repo, Headroom stacks on top of every AGW mode.**

| Large repo (`k8s-iceman`) | OFF $ | ON $ | Headroom saving |
|---|---:|---:|---:|
| Standard | 0.0424 | 0.0391 | −8% |
| Search | 0.0269 | 0.0173 | **−36%** |
| Code | 0.0623 | 0.0233 | **−63%** |

The cheapest *reliable* cell overall is **Search + Headroom ($0.0173)** — AGW kills the catalog
tax (−91% tool context), Headroom kills the result-JSON payload. **Code + Headroom (−63%)** is
the single biggest stack, because Code's summarize-only output and Headroom's compression
compound. This is the headline: **AGW + Headroom > either alone, on real payloads.**

**2. On a small repo, Headroom does not help — and actively hurts Standard.**

| Small repo (`sandbox`) | OFF $ | ON $ | Headroom saving |
|---|---:|---:|---:|
| Standard | 0.0289 | 0.0432 | **−49% (WORSE)** |
| Search | 0.0149 | 0.0138 | +7% |
| Code | 0.0315 | 0.0204 | +35% |

With little result data to compress, Headroom's gain is small — and on Standard it *loses*,
because rewriting the prompt every turn **busts gpt-5.5's prefix cache**, which otherwise serves
the big stable 28-tool catalog cheaply. The lost cache outweighs the compression. **Payload
compression needs payloads.**

**3. Quality caveat — cheaper is not free.** The `commits` question repeatedly scored **2/5**
under Headroom ON: text compression mangles high-entropy **commit SHA hashes**. For tasks that
need verbatim identifiers, Headroom degrades accuracy. Most other answers held at 4–5/5.

**4. Compatibility caveat — not a clean drop-in.** Out of the box, Headroom's semantic cache and
CCR tool-injection **broke the Search/Code tool-orchestration flow** (every such ON task failed
with an MCP TaskGroup error). It only worked once launched with
`--no-cache --no-ccr-inject-tool --no-ccr-marker`. In front of an MCP tool-calling agent, those
flags are mandatory.

## So should you run both?

```
Large result payloads (logs, file contents, big JSON)  → YES: AGW Search/Code + Headroom stacks (−36% to −63%)
Small catalog-dominated workload                       → AGW alone; Headroom can hurt (cache-bust)
Tasks needing exact IDs (SHAs, tokens, hashes)         → be careful: Headroom mangles them
MCP tool-calling agent                                 → Headroom needs --no-cache --no-ccr-* to not break
```

They are **complementary, not competing** — AGW on the catalog, Headroom on the payload — and on
the right workload they genuinely compound. But Headroom's benefit is entirely payload-dependent,
it can regress cache-friendly workloads, and it trades a little accuracy on exact-identifier
tasks.

## Method & honesty notes

- Cost = cache-aware gpt-5.5 list-price; quality = LLM judge (0–5) vs the Standard/OFF answer.
- **Single run.** Demo 104 showed real run-to-run variance; treat ±a few points as noise and
  re-run `./run_matrix.sh` 3× for firm ranges before quoting.
- Headroom ran in `--mode token` (max compression), `--stateless`, conservative default
  `--target-ratio` (Kompress decides). More aggressive ratios would save more but risk quality.
- Live dashboards: `kubectl port-forward svc/grafana -n observability 3001:80` → http://localhost:3001
  (admin/admin), dashboard "AGW Tool Modes + Headroom". Replay saved data with
  `observability/replay_to_pushgateway.py` (no LLM spend).

## See also

- Demo **104** — AGW tool modes alone on this exact GitHub workload (no compression).
- Demo **103** — the small-catalog (F5) contrast.
