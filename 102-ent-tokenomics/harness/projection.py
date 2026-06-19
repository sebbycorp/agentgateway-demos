"""Project per-task cost into business $/month at realistic agent-call volumes.

Reads harness/results.csv, averages cost per (provider, mode, cache_state), and
projects $/day and $/month for several daily call volumes, plus $ saved/month vs
Standard mode. Writes projection.csv and pushes gauges for the Grafana Deep-Dive
dashboard.

NOTE on Anthropic caching: cache tokens were not observed through AGW v2026.6.1,
so Anthropic 'warm' rows reflect uncached reality. The cache-aware column still
applies the published Anthropic cache rates to whatever cache tokens are present
(0 today), so the projection is honest: it shows the *measured* economics and is
ready to reflect real Anthropic cache savings the moment the gateway surfaces them.
"""
import csv
import os
import pathlib

from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

HERE = pathlib.Path(__file__).parent
PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "http://localhost:9091")
VOLUMES = [int(x) for x in os.environ.get("VOLUMES", "10000,50000,200000").split(",")]
DAYS_PER_MONTH = 30


def load_rows():
    with open(HERE / "results.csv") as f:
        return list(csv.DictReader(f))


def avg_cost(rows):
    """avg cache-aware USD per task keyed by (provider, mode, cache_state)."""
    agg = {}
    for r in rows:
        key = (r["provider"], r["mode"], r["cache_state"])
        agg.setdefault(key, []).append(float(r["usd_cost_cached"]))
    return {k: sum(v) / len(v) for k, v in agg.items()}


def main():
    rows = load_rows()
    if not rows:
        print("results.csv is empty — run run_ab.py first.")
        return
    costs = avg_cost(rows)
    providers = sorted({r["provider"] for r in rows})
    modes = ["standard", "search", "code", "codesearch"]
    states = sorted({r["cache_state"] for r in rows})

    out_rows = []
    reg = CollectorRegistry()
    g_month = Gauge("agw_proj_usd_per_month", "projected USD/month",
                    ["provider", "mode", "cache_state", "volume"], registry=reg)
    g_saved = Gauge("agw_proj_usd_saved_per_month_vs_standard", "USD/month saved vs standard",
                    ["provider", "mode", "cache_state", "volume"], registry=reg)

    print("\n=== Projected $/month (cache-aware) and savings vs Standard ===")
    for provider in providers:
        for state in states:
            base = costs.get((provider, "standard", state))
            print(f"\n[{provider} / {state} cache]")
            for vol in VOLUMES:
                line = f"  {vol:>7,}/day:"
                for mode in modes:
                    c = costs.get((provider, mode, state))
                    if c is None:
                        continue
                    per_month = c * vol * DAYS_PER_MONTH
                    saved = (base - c) * vol * DAYS_PER_MONTH if base is not None else 0.0
                    out_rows.append({
                        "provider": provider, "mode": mode, "cache_state": state,
                        "calls_per_day": vol,
                        "usd_per_day": round(c * vol, 4),
                        "usd_per_month": round(per_month, 2),
                        "usd_saved_per_month_vs_standard": round(saved, 2),
                    })
                    g_month.labels(provider=provider, mode=mode, cache_state=state, volume=str(vol)).set(per_month)
                    g_saved.labels(provider=provider, mode=mode, cache_state=state, volume=str(vol)).set(saved)
                    tag = "" if mode == "standard" else f" (save ${saved:,.0f})"
                    line += f"  {mode}=${per_month:,.0f}{tag}"
                print(line)

    with open(HERE / "projection.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[
            "provider", "mode", "cache_state", "calls_per_day",
            "usd_per_day", "usd_per_month", "usd_saved_per_month_vs_standard"])
        w.writeheader()
        w.writerows(out_rows)
    print(f"\nWrote {HERE / 'projection.csv'} ({len(out_rows)} rows)")

    try:
        push_to_gateway(PUSHGATEWAY, job="agw_progressive_disclosure_projection", registry=reg)
        print(f"Pushed projection metrics to {PUSHGATEWAY}")
    except Exception as e:
        print(f"WARN: could not push projection ({e}); projection.csv still written")


if __name__ == "__main__":
    main()
