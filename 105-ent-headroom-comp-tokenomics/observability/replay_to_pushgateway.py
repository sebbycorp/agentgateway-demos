"""Replay an already-collected matrix run into the Prometheus pushgateway WITHOUT
re-spending on LLM calls. Reads harness/results.jsonl (cost/token metrics) and,
optionally, the run log (judge quality scores) and pushes the same agw_hr_* /
agw_hr_quality_score series the live harness would, so the Grafana dashboard
populates from saved data.

Usage:
  ./.venv/bin/python observability/replay_to_pushgateway.py \
      [results.jsonl] [run-log-with-judge-scores]
Prereqs: pushgateway port-forwarded to :9091.
"""
import json
import os
import re
import sys

from prometheus_client import CollectorRegistry, Gauge, delete_from_gateway, push_to_gateway

PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "http://localhost:9091")
HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "harness", "results.jsonl")
JUDGE_LOG = sys.argv[2] if len(sys.argv) > 2 else None


def main():
    rows = [json.loads(l) for l in open(RESULTS) if l.strip()]
    reg = CollectorRegistry()
    lbl = ["question", "mode", "headroom", "repo"]
    g_cost = Gauge("agw_hr_usd_cost", "USD cost per task", lbl, registry=reg)
    g_total = Gauge("agw_hr_total_tokens", "total tokens per task", lbl, registry=reg)
    g_first = Gauge("agw_hr_first_call_tokens", "first-call tool tokens", lbl, registry=reg)
    g_calls = Gauge("agw_hr_llm_calls", "LLM round-trips", lbl, registry=reg)
    g_ok = Gauge("agw_hr_task_ok", "task answered", lbl, registry=reg)
    for r in rows:
        k = dict(question=r["question"], mode=r["mode"], headroom=r["headroom"], repo=r["repo"])
        g_cost.labels(**k).set(r.get("cost", 0))
        g_total.labels(**k).set(r.get("total", 0))
        g_first.labels(**k).set(r.get("first", 0))
        g_calls.labels(**k).set(r.get("calls", 0))
        g_ok.labels(**k).set(1 if r.get("ok") else 0)

    # Optional: parse judge score lines ("repo mode hr question score why") from a log.
    n_scores = 0
    if JUDGE_LOG and os.path.exists(JUDGE_LOG):
        g_q = Gauge("agw_hr_quality_score", "0-5 answer quality vs baseline", lbl, registry=reg)
        repos = sorted({r["repo"] for r in rows}, key=len, reverse=True)  # match longest first
        # repo and mode may be concatenated (long repo name) or space-separated
        # (short name padded by the table), so allow optional whitespace between.
        pat = re.compile(r"^\s*(?P<repo>\S+?)\s*(?P<mode>standard|search|code)\s+(?P<hr>off|on)\s+"
                         r"(?P<q>repo|commits|issues|prs|contents)\s+(?P<score>[0-5])\b")
        for line in open(JUDGE_LOG):
            m = pat.match(line)
            if not m:
                continue
            repo = next((rp for rp in repos if line.lstrip().startswith(rp)), m.group("repo"))
            g_q.labels(question=m.group("q"), mode=m.group("mode"),
                       headroom=m.group("hr"), repo=repo).set(int(m.group("score")))
            n_scores += 1

    try:
        delete_from_gateway(PUSHGATEWAY, job="agw_hr_questions")
    except Exception:
        pass
    push_to_gateway(PUSHGATEWAY, job="agw_hr_questions", registry=reg)
    print(f"Replayed {len(rows)} cost rows" + (f" + {n_scores} quality scores" if n_scores else "")
          + f" to {PUSHGATEWAY} (job=agw_hr_questions)")


if __name__ == "__main__":
    main()
