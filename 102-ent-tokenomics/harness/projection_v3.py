"""Project eval-framework per-task cost into business $/month at realistic agent
volumes, broken down by mode and agentic-loop length (the compounding story).

Reads results_v3.csv (written by eval.py), averages cache-aware USD per
(provider, model, mode, loop_k), projects $/day and $/month for several daily
call volumes, computes $ saved/month vs Standard mode, writes projection_v3.csv,
and pushes gauges for the Evaluation dashboard.
"""
import csv
import os
import pathlib

from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

HERE = pathlib.Path(__file__).parent
PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "http://localhost:9091")
VOLUMES = [int(x) for x in os.environ.get("VOLUMES", "10000,50000,200000").split(",")]
RESULTS_CSV = os.environ.get("RESULTS_CSV", str(HERE / "results_v3.csv"))
DAYS_PER_MONTH = 30


def load_rows():
    with open(RESULTS_CSV) as f:
        return list(csv.DictReader(f))


def avg_cost(rows):
    """avg cache-aware USD per task keyed by (provider, model, mode, loop_k)."""
    agg = {}
    for r in rows:
        key = (r["provider"], r["model"], r["mode"], r["loop_k"])
        agg.setdefault(key, []).append(float(r["usd_cost_cached"]))
    return {k: sum(v) / len(v) for k, v in agg.items()}


def main():
    rows = load_rows()
    if not rows:
        print("results_v3.csv is empty — run eval.py first.")
        return
    costs = avg_cost(rows)
    providers = sorted({r["provider"] for r in rows})
    modes = ["standard", "search", "code", "codesearch"]
    loop_ks = sorted({r["loop_k"] for r in rows}, key=lambda x: int(x))

    out_rows = []
    reg = CollectorRegistry()
    g_month = Gauge("agw_eval_proj_usd_per_month", "projected USD/month",
                    ["provider", "model", "mode", "loop_k", "volume"], registry=reg)
    g_saved = Gauge("agw_eval_proj_saved_per_month_vs_standard", "USD/month saved vs standard",
                    ["provider", "model", "mode", "loop_k", "volume"], registry=reg)

    print("\n=== Projected $/month by mode & agentic-loop length ===")
    for provider in providers:
        models = sorted({r["model"] for r in rows if r["provider"] == provider})
        for model in models:
            for lk in loop_ks:
                base = costs.get((provider, model, "standard", lk))
                print(f"\n[{provider}/{model} · loop_k={lk}]")
                for mode in modes:
                    c = costs.get((provider, model, mode, lk))
                    if c is None:
                        continue
                    line = f"  {mode:>10}:"
                    for vol in VOLUMES:
                        per_month = c * vol * DAYS_PER_MONTH
                        saved = (base - c) * vol * DAYS_PER_MONTH if base is not None else 0.0
                        out_rows.append({
                            "provider": provider, "model": model, "mode": mode,
                            "loop_k": lk, "calls_per_day": vol,
                            "usd_per_month": round(per_month, 2),
                            "usd_saved_per_month_vs_standard": round(saved, 2),
                        })
                        g_month.labels(provider=provider, model=model, mode=mode,
                                       loop_k=str(lk), volume=str(vol)).set(per_month)
                        g_saved.labels(provider=provider, model=model, mode=mode,
                                       loop_k=str(lk), volume=str(vol)).set(saved)
                        line += f"  {vol//1000}k/d=${per_month:,.0f}"
                    print(line)

    with open(HERE / "projection_v3.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[
            "provider", "model", "mode", "loop_k", "calls_per_day",
            "usd_per_month", "usd_saved_per_month_vs_standard"])
        w.writeheader()
        w.writerows(out_rows)
    print(f"\nWrote {HERE / 'projection_v3.csv'} ({len(out_rows)} rows)")

    try:
        push_to_gateway(PUSHGATEWAY, job="agw_eval_v3_projection", registry=reg)
        print(f"Pushed projection metrics to {PUSHGATEWAY}")
    except Exception as e:
        print(f"WARN: could not push projection ({e}); projection_v3.csv still written")


if __name__ == "__main__":
    main()
