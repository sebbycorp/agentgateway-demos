"""LLM-judge answer-quality scorer for the 105 Headroom comparison.

Headroom changes what the model sees, so a cheaper cell is only a win if the
answer is still right. This reads results.jsonl (written by gh_questions.py),
takes the Standard / Headroom-OFF answer per (repo, question) as the reference
BASELINE, and asks a judge model to score every other cell's answer 0-5 for
factual match + completeness vs that baseline.

The judge call always goes OFF-path (uncompressed) so the grader itself is never
compressed. Scores are pushed as agw_hr_quality_score{repo,mode,headroom,question}
and printed as a table.

Prereqs: proxy port-forwarded to :8080 (+ pushgateway :9091 to push scores).
Backend gpt-5.5 -> set LLM_NO_TEMPERATURE=1.
Usage:  RESULTS_FILE=results.jsonl ./.venv/bin/python judge.py
"""
import collections
import json
import os

import httpx
from prometheus_client import CollectorRegistry, Gauge, delete_from_gateway, push_to_gateway

GW = os.environ.get("GATEWAY_URL", "http://localhost:8080")
# Always the OFF-path /openai: the judge must read uncompressed text.
JUDGE_LLM = os.environ.get("JUDGE_LLM_URL", GW + "/openai")
PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "http://localhost:9091")
RESULTS_FILE = os.environ.get("RESULTS_FILE", "results.jsonl")
NO_TEMP = os.environ.get("LLM_NO_TEMPERATURE", "").lower() in ("1", "true", "yes")

JUDGE_SYS = (
    "You are a strict grader. Given a QUESTION, a reference BASELINE answer, and a "
    "CANDIDATE answer, score how well the candidate matches the baseline's factual "
    "content and completeness, from 0 (wrong, empty, or refuses) to 5 (fully "
    "equivalent in facts and coverage). Ignore wording/formatting differences. "
    'Reply with ONLY a JSON object: {"score": <int 0-5>, "why": "<one short line>"}.'
)


def load_rows():
    with open(RESULTS_FILE) as f:
        return [json.loads(line) for line in f if line.strip()]


def score(client, question, baseline, candidate):
    body = {"model": "", "messages": [
        {"role": "system", "content": JUDGE_SYS},
        {"role": "user", "content": f"QUESTION:\n{question}\n\nBASELINE:\n{baseline}\n\nCANDIDATE:\n{candidate}"},
    ]}
    if not NO_TEMP:
        body["temperature"] = 0
    resp = client.post(JUDGE_LLM, json=body, timeout=120).json()
    txt = resp["choices"][0]["message"].get("content", "") or ""
    try:
        obj = json.loads(txt[txt.find("{"): txt.rfind("}") + 1])
        return max(0, min(5, int(obj.get("score", 0)))), str(obj.get("why", ""))
    except Exception:
        return 0, f"unparseable judge reply: {txt[:80]}"


def main():
    data = load_rows()
    if not data:
        print(f"No rows in {RESULTS_FILE}; run gh_questions.py (or run_matrix.sh) first.")
        return

    # Baseline = Standard + Headroom-OFF answer for each (repo, question).
    baseline = {}
    for r in data:
        if r["mode"] == "standard" and r["headroom"] == "off":
            baseline[(r["repo"], r["question"])] = r.get("answer", "")

    reg = CollectorRegistry()
    g = Gauge("agw_hr_quality_score", "0-5 answer quality vs Standard/OFF baseline",
              ["repo", "mode", "headroom", "question"], registry=reg)

    by_cell = collections.defaultdict(list)  # (repo,mode,headroom) -> [scores]
    print(f"{'repo':<30}{'mode':<10}{'hr':<5}{'question':<10}{'score':>6}  why")
    print("-" * 90)
    with httpx.Client() as client:
        for r in data:
            base = baseline.get((r["repo"], r["question"]))
            if base is None:
                print(f"  (skip {r['repo']} {r['question']}: no baseline answer recorded)")
                continue
            s, why = score(client, r["question"], base, r.get("answer", ""))
            g.labels(repo=r["repo"], mode=r["mode"], headroom=r["headroom"],
                     question=r["question"]).set(s)
            by_cell[(r["repo"], r["mode"], r["headroom"])].append(s)
            print(f"{r['repo']:<30}{r['mode']:<10}{r['headroom']:<5}{r['question']:<10}{s:>6}  {why[:50]}")

    print("\n=== mean quality per cell (repo / mode / headroom) ===")
    for (repo, mode, hr), scores in sorted(by_cell.items()):
        avg = sum(scores) / len(scores)
        print(f"  {repo:<30}{mode:<10}{hr:<5} mean={avg:.2f}  (n={len(scores)})")

    try:
        delete_from_gateway(PUSHGATEWAY, job="agw_hr_quality")
    except Exception:
        pass
    try:
        push_to_gateway(PUSHGATEWAY, job="agw_hr_quality", registry=reg)
        print(f"\nPushed quality scores to {PUSHGATEWAY} (job=agw_hr_quality)")
    except Exception as e:
        print(f"\nWARN: could not push ({e})")


if __name__ == "__main__":
    main()
