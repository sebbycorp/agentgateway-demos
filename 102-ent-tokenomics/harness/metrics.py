"""metrics.py — token/cost normalization and Prometheus push for the eval framework.

Reuses usage_norm() and cost() verbatim from run_ab.py (v2 harness), extended
for the new schema labels: provider, mode, persona, catalog_size, loop_k,
cache_state, plus accuracy and loop metrics.
"""
from __future__ import annotations

import json
import os
import pathlib
from typing import Any, Dict, List

HERE = pathlib.Path(__file__).parent
PRICING = json.loads((HERE / "pricing.json").read_text())

PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "http://localhost:9091")
JOB_NAME = "agw_eval_v3"


# ---------------------------------------------------------------------------
# Usage normalization (verbatim from run_ab.py)
# ---------------------------------------------------------------------------

def usage_norm(u: Dict[str, Any]) -> Dict[str, int]:
    """Normalize an OpenAI-compat usage dict into canonical field names.

    Handles both OpenAI (prompt_tokens_details.cached_tokens) and Anthropic
    (cache_read_input_tokens / cache_creation_input_tokens) cache fields.
    Returns a dict with always-present integer keys.
    """
    ptd = u.get("prompt_tokens_details") or {}
    return {
        "prompt_tokens": u.get("prompt_tokens", 0) or 0,
        "completion_tokens": u.get("completion_tokens", 0) or 0,
        "cached_tokens": ptd.get("cached_tokens", 0) or 0,
        "cache_write_tokens": u.get("cache_creation_input_tokens", 0) or 0,
        "cache_read_tokens": u.get("cache_read_input_tokens", 0) or 0,
    }


# ---------------------------------------------------------------------------
# Cost calculation (verbatim from run_ab.py)
# ---------------------------------------------------------------------------

def cost(
    model: str,
    prompt_tokens: int,
    completion_tokens: int,
    cached: int,
    write: int,
    read: int,
    cache_aware: bool,
) -> float:
    """Calculate USD cost for one task.

    cache_aware=False  → use flat input_per_1k (baseline uncached cost).
    cache_aware=True   → apply cache discount based on model pricing style.
      - OpenAI style: cached_input_per_1k for the cached portion.
      - Anthropic style: cache_write_per_1k / cache_read_per_1k for W/R tokens.

    Raises KeyError if model is not in pricing.json.
    """
    p = PRICING[model]
    out_cost = (completion_tokens / 1000.0) * p["output_per_1k"]

    if not cache_aware:
        return (prompt_tokens / 1000.0) * p["input_per_1k"] + out_cost

    if "cached_input_per_1k" in p:       # OpenAI-style automatic caching
        uncached = max(prompt_tokens - cached, 0)
        return (
            (uncached / 1000.0) * p["input_per_1k"]
            + (cached / 1000.0) * p["cached_input_per_1k"]
            + out_cost
        )

    if "cache_write_per_1k" in p:        # Anthropic-style explicit cache_control
        rest = max(prompt_tokens - write - read, 0)
        return (
            (rest / 1000.0) * p["input_per_1k"]
            + (write / 1000.0) * p["cache_write_per_1k"]
            + (read / 1000.0) * p["cache_read_per_1k"]
            + out_cost
        )

    # Fallback: treat as flat input
    return (prompt_tokens / 1000.0) * p["input_per_1k"] + out_cost


# ---------------------------------------------------------------------------
# Prometheus push
# ---------------------------------------------------------------------------

def push_metrics(rows: List[Dict[str, Any]]) -> None:
    """Aggregate rows and push Prometheus gauges to the pushgateway.

    Labels: provider, model, mode, persona, target, catalog_size, loop_k, task_id.
    Gauges: tokens, cache, cost, latency, llm_calls, accuracy, task_ok.

    Failures are non-fatal (prints WARN); CSV/JSON are written before this call.
    """
    try:
        from prometheus_client import (
            CollectorRegistry, Gauge,
            delete_from_gateway, push_to_gateway,
        )
    except ImportError:
        print("WARN: prometheus_client not installed; skipping metrics push")
        return

    if not rows:
        return

    reg = CollectorRegistry()
    label_names = ["provider", "model", "mode", "persona", "target",
                   "catalog_size", "loop_k", "task_id"]

    def _g(name: str, doc: str) -> "Gauge":
        return Gauge(name, doc, label_names, registry=reg)

    gauges = {
        "agw_v3_first_call_prompt_tokens":
            _g("agw_v3_first_call_prompt_tokens", "avg first-call prompt tokens"),
        "agw_v3_total_prompt_tokens":
            _g("agw_v3_total_prompt_tokens", "avg total prompt tokens per task"),
        "agw_v3_completion_tokens":
            _g("agw_v3_completion_tokens", "avg completion tokens per task"),
        "agw_v3_cached_tokens":
            _g("agw_v3_cached_tokens", "avg cached tokens per task"),
        "agw_v3_cache_write_tokens":
            _g("agw_v3_cache_write_tokens", "avg cache-write tokens per task"),
        "agw_v3_cache_read_tokens":
            _g("agw_v3_cache_read_tokens", "avg cache-read tokens per task"),
        "agw_v3_total_tokens":
            _g("agw_v3_total_tokens", "avg total tokens per task"),
        "agw_v3_llm_calls":
            _g("agw_v3_llm_calls", "avg LLM round-trips per task"),
        "agw_v3_latency_ms":
            _g("agw_v3_latency_ms", "avg task latency ms"),
        "agw_v3_usd_cost_cached":
            _g("agw_v3_usd_cost_cached", "avg cache-aware USD per task"),
        "agw_v3_usd_cost_uncached":
            _g("agw_v3_usd_cost_uncached", "avg uncached USD per task"),
        "agw_v3_accuracy":
            _g("agw_v3_accuracy", "top-1 tool accuracy rate (correct/samples)"),
        "agw_v3_task_ok":
            _g("agw_v3_task_ok", "task success rate"),
        "agw_v3_advertised_tools":
            _g("agw_v3_advertised_tools", "advertised tool count"),
    }

    # Aggregate by label key.
    agg: Dict[tuple, List[Dict[str, Any]]] = {}
    for row in rows:
        key = (
            str(row.get("provider", "")),
            str(row.get("model", "")),
            str(row.get("mode", "")),
            str(row.get("persona", "none")),
            str(row.get("target", "")),
            str(row.get("catalog_size", 0)),
            str(row.get("loop_k", 0)),
            str(row.get("task_id", "")),
        )
        agg.setdefault(key, []).append(row)

    def _avg(rs: List[Dict], field: str) -> float:
        vals = [float(r.get(field, 0) or 0) for r in rs]
        return sum(vals) / len(vals) if vals else 0.0

    for key, rs in agg.items():
        prov, model, mode, persona, target, catalog_size, loop_k, task_id = key
        lbl = dict(provider=prov, model=model, mode=mode, persona=persona,
                   target=target, catalog_size=catalog_size, loop_k=loop_k,
                   task_id=task_id)
        n = len(rs)
        gauges["agw_v3_first_call_prompt_tokens"].labels(**lbl).set(_avg(rs, "first_call_prompt_tokens"))
        gauges["agw_v3_total_prompt_tokens"].labels(**lbl).set(_avg(rs, "total_prompt_tokens"))
        gauges["agw_v3_completion_tokens"].labels(**lbl).set(_avg(rs, "completion_tokens"))
        gauges["agw_v3_cached_tokens"].labels(**lbl).set(_avg(rs, "cached_tokens"))
        gauges["agw_v3_cache_write_tokens"].labels(**lbl).set(_avg(rs, "cache_write_tokens"))
        gauges["agw_v3_cache_read_tokens"].labels(**lbl).set(_avg(rs, "cache_read_tokens"))
        gauges["agw_v3_total_tokens"].labels(**lbl).set(_avg(rs, "total_tokens"))
        gauges["agw_v3_llm_calls"].labels(**lbl).set(_avg(rs, "llm_calls"))
        gauges["agw_v3_latency_ms"].labels(**lbl).set(_avg(rs, "latency_ms"))
        gauges["agw_v3_usd_cost_cached"].labels(**lbl).set(_avg(rs, "usd_cost_cached"))
        gauges["agw_v3_usd_cost_uncached"].labels(**lbl).set(_avg(rs, "usd_cost_uncached"))
        gauges["agw_v3_accuracy"].labels(**lbl).set(
            sum(1 for r in rs if r.get("correct")) / n
        )
        gauges["agw_v3_task_ok"].labels(**lbl).set(
            sum(1 for r in rs if r.get("task_ok")) / n
        )
        if rs:
            gauges["agw_v3_advertised_tools"].labels(**lbl).set(
                rs[0].get("advertised_tools", 0)
            )

    try:
        delete_from_gateway(PUSHGATEWAY, job=JOB_NAME)
    except Exception:
        pass

    try:
        push_to_gateway(PUSHGATEWAY, job=JOB_NAME, registry=reg)
        print(f"Pushed metrics to {PUSHGATEWAY} (job={JOB_NAME})")
    except Exception as exc:
        print(f"WARN: could not push to pushgateway ({exc}); CSV/JSON still written")
