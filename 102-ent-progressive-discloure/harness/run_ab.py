"""A/B harness v2: prove MCP progressive-disclosure savings across providers,
tool modes, tool counts, and cache states.

For each (provider x mode x tool_count x run) it runs an identical multi-tool
agent task COLD then WARM (back-to-back, to exercise prompt caching), connecting
to the gateway MCP route, driving the LLM through the gateway, executing tool
calls back through MCP, and capturing the full token / cache / latency /
round-trip breakdown. Results -> CSV/JSON + Prometheus Pushgateway.

Both providers use AGW's OpenAI-compatible schema; the unified `usage` object
carries OpenAI (`cached_tokens`) and Anthropic (`cache_read/creation`) cache
fields. OpenAI caches automatically (>=1024-token prompts, 50% off). Anthropic
cache tokens were not observed in AGW v2026.6.1 even with the promptCaching
policy applied, so Anthropic cache economics are MODELED in projection.py.
"""
import asyncio
import csv
import json
import os
import pathlib
import time

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from prometheus_client import CollectorRegistry, Gauge, delete_from_gateway, push_to_gateway

GATEWAY = os.environ.get("GATEWAY_URL", "http://localhost:8080")
PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "http://localhost:9091")
RUNS = int(os.environ.get("RUNS", "3"))
TOOL_COUNTS = [int(x) for x in os.environ.get("TOOL_COUNTS", "10,50,100").split(",")]
MODES = os.environ.get("MODES", "standard,search,code,codesearch").split(",")
PROVIDERS = os.environ.get("PROVIDERS", "openai,anthropic").split(",")
CACHE_STATES = ["cold", "warm"]
MAX_TOOL_TURNS = 8

PROVIDER_ROUTE = {"openai": "/openai", "anthropic": "/anthropic"}
PROVIDER_MODEL = {"openai": "gpt-4o-mini", "anthropic": "claude-sonnet-4-6"}
EXPECTED_TOOLS = {"standard": None, "search": 2, "code": 1, "codesearch": 2}  # None=tool_count

HERE = pathlib.Path(__file__).parent
PRICING = json.loads((HERE / "pricing.json").read_text())

# Multi-step task: needs two distinct tools (indices < 10 so present at every count).
TASK = (
    "Use the available tools to do BOTH of the following, then reply with the two "
    "returned strings joined by ' | ':\n"
    "1) call the tool named tool_003 with text='alpha' and number=1\n"
    "2) call the tool named tool_005 with text='beta' and number=2"
)

FIELDS = [
    "provider", "model", "mode", "tool_count", "run", "cache_state",
    "advertised_tools", "first_call_prompt_tokens", "total_prompt_tokens",
    "completion_tokens", "cached_tokens", "cache_write_tokens", "cache_read_tokens",
    "total_tokens", "llm_calls", "latency_ms", "usd_cost_uncached",
    "usd_cost_cached", "task_ok",
]


def mcp_tools_to_openai(tools):
    out = []
    for t in tools:
        out.append({
            "type": "function",
            "function": {
                "name": t.name,
                "description": t.description or "",
                "parameters": t.inputSchema or {"type": "object", "properties": {}},
            },
        })
    return out


def usage_norm(u):
    ptd = u.get("prompt_tokens_details") or {}
    return {
        "prompt_tokens": u.get("prompt_tokens", 0) or 0,
        "completion_tokens": u.get("completion_tokens", 0) or 0,
        "cached_tokens": ptd.get("cached_tokens", 0) or 0,
        "cache_write_tokens": u.get("cache_creation_input_tokens", 0) or 0,
        "cache_read_tokens": u.get("cache_read_input_tokens", 0) or 0,
    }


def cost(model, prompt_tokens, completion_tokens, cached, write, read, cache_aware):
    p = PRICING[model]
    out = (completion_tokens / 1000.0) * p["output_per_1k"]
    if not cache_aware:
        return (prompt_tokens / 1000.0) * p["input_per_1k"] + out
    if "cached_input_per_1k" in p:  # OpenAI-style: cached portion discounted
        uncached = max(prompt_tokens - cached, 0)
        return (uncached / 1000.0) * p["input_per_1k"] \
            + (cached / 1000.0) * p["cached_input_per_1k"] + out
    if "cache_write_per_1k" in p:  # Anthropic-style: write/read priced separately
        rest = max(prompt_tokens - write - read, 0)
        return (rest / 1000.0) * p["input_per_1k"] \
            + (write / 1000.0) * p["cache_write_per_1k"] \
            + (read / 1000.0) * p["cache_read_per_1k"] + out
    return (prompt_tokens / 1000.0) * p["input_per_1k"] + out


async def run_one(provider, mode, count, run_idx, cache_state, client):
    route = f"/mcp/{mode}-{count}"
    llm_url = GATEWAY + PROVIDER_ROUTE[provider]
    model = PROVIDER_MODEL[provider]
    async with streamablehttp_client(f"{GATEWAY}{route}") as (r, w, _):
        async with ClientSession(r, w) as session:
            await session.initialize()
            tools = (await session.list_tools()).tools
            openai_tools = mcp_tools_to_openai(tools)
            messages = [{"role": "user", "content": TASK}]
            first_prompt = None
            total_prompt = completion = cached = write = read = llm_calls = 0
            t0 = time.perf_counter()
            for _ in range(MAX_TOOL_TURNS):
                resp = (await client.post(llm_url, json={
                    "model": "", "temperature": 0, "seed": 42,
                    "messages": messages, "tools": openai_tools,
                })).json()
                llm_calls += 1
                u = usage_norm(resp.get("usage", {}))
                total_prompt += u["prompt_tokens"]
                completion += u["completion_tokens"]
                cached += u["cached_tokens"]
                write += u["cache_write_tokens"]
                read += u["cache_read_tokens"]
                if first_prompt is None:
                    first_prompt = u["prompt_tokens"]
                choice = resp["choices"][0]["message"]
                messages.append(choice)
                calls = choice.get("tool_calls") or []
                if not calls:
                    break
                for call in calls:
                    fn = call["function"]["name"]
                    args = json.loads(call["function"]["arguments"] or "{}")
                    try:
                        res = await session.call_tool(fn, arguments=args)
                        text = res.content[0].text if res.content else ""
                    except Exception as e:
                        text = f"tool error: {e}"
                    messages.append({"role": "tool", "tool_call_id": call["id"], "content": text})
            latency_ms = (time.perf_counter() - t0) * 1000.0
            blob = " ".join(
                str(m.get("content", "")) for m in messages if isinstance(m.get("content"), str)
            )
            task_ok = ("tool_003" in blob and "tool_005" in blob and "echoed" in blob)
            return {
                "provider": provider, "model": model, "mode": mode, "tool_count": count,
                "run": run_idx, "cache_state": cache_state, "advertised_tools": len(tools),
                "first_call_prompt_tokens": first_prompt or 0,
                "total_prompt_tokens": total_prompt, "completion_tokens": completion,
                "cached_tokens": cached, "cache_write_tokens": write, "cache_read_tokens": read,
                "total_tokens": total_prompt + completion, "llm_calls": llm_calls,
                "latency_ms": round(latency_ms, 1),
                "usd_cost_uncached": round(cost(model, total_prompt, completion, cached, write, read, False), 8),
                "usd_cost_cached": round(cost(model, total_prompt, completion, cached, write, read, True), 8),
                "task_ok": task_ok,
            }


def push_metrics(rows):
    reg = CollectorRegistry()
    labels = ["provider", "mode", "tool_count", "cache_state"]
    gauges = {
        "agw_first_call_prompt_tokens": Gauge("agw_first_call_prompt_tokens", "avg first-call prompt tokens", labels, registry=reg),
        "agw_total_tokens": Gauge("agw_total_tokens", "avg total tokens per task", labels, registry=reg),
        "agw_llm_calls": Gauge("agw_llm_calls", "avg LLM round-trips per task", labels, registry=reg),
        "agw_latency_ms": Gauge("agw_latency_ms", "avg task latency ms", labels, registry=reg),
        "agw_usd_cost_cached": Gauge("agw_usd_cost_cached", "avg cache-aware USD per task", labels, registry=reg),
        "agw_usd_cost_uncached": Gauge("agw_usd_cost_uncached", "avg uncached USD per task", labels, registry=reg),
        "agw_advertised_tools": Gauge("agw_advertised_tools", "tools advertised", labels, registry=reg),
        "agw_task_ok": Gauge("agw_task_ok", "task success rate", labels, registry=reg),
    }
    agg = {}
    for row in rows:
        key = (row["provider"], row["mode"], str(row["tool_count"]), row["cache_state"])
        agg.setdefault(key, []).append(row)
    for (prov, mode, count, state), rs in agg.items():
        n = len(rs)
        lbl = {"provider": prov, "mode": mode, "tool_count": count, "cache_state": state}
        gauges["agw_first_call_prompt_tokens"].labels(**lbl).set(sum(r["first_call_prompt_tokens"] for r in rs) / n)
        gauges["agw_total_tokens"].labels(**lbl).set(sum(r["total_tokens"] for r in rs) / n)
        gauges["agw_llm_calls"].labels(**lbl).set(sum(r["llm_calls"] for r in rs) / n)
        gauges["agw_latency_ms"].labels(**lbl).set(sum(r["latency_ms"] for r in rs) / n)
        gauges["agw_usd_cost_cached"].labels(**lbl).set(sum(r["usd_cost_cached"] for r in rs) / n)
        gauges["agw_usd_cost_uncached"].labels(**lbl).set(sum(r["usd_cost_uncached"] for r in rs) / n)
        gauges["agw_advertised_tools"].labels(**lbl).set(rs[0]["advertised_tools"])
        gauges["agw_task_ok"].labels(**lbl).set(sum(1 for r in rs if r["task_ok"]) / n)
    try:
        delete_from_gateway(PUSHGATEWAY, job="agw_progressive_disclosure")
    except Exception:
        pass
    try:
        push_to_gateway(PUSHGATEWAY, job="agw_progressive_disclosure", registry=reg)
        print(f"Pushed metrics to {PUSHGATEWAY}")
    except Exception as e:
        print(f"WARN: could not push to pushgateway ({e}); CSV/JSON still written")


def print_summary(rows):
    print("\n=== Search/Code-mode savings (first-call prompt tokens, cold) ===")
    counts = sorted({r["tool_count"] for r in rows})
    for prov in sorted({r["provider"] for r in rows}):
        print(f"\n[{prov}]")
        for count in counts:
            line = f"  {count:>3} tools:"
            base = None
            for mode in ["standard", "search", "code", "codesearch"]:
                vals = [r["first_call_prompt_tokens"] for r in rows
                        if r["provider"] == prov and r["mode"] == mode
                        and r["tool_count"] == count and r["cache_state"] == "cold"]
                if not vals:
                    continue
                avg = sum(vals) / len(vals)
                if mode == "standard":
                    base = avg
                pct = f" ({(base - avg) / base * 100:4.0f}% less)" if base and mode != "standard" else ""
                line += f"  {mode}={avg:.0f}{pct}"
            print(line)


async def main():
    rows = []
    async with httpx.AsyncClient(timeout=120) as client:
        for provider in PROVIDERS:
            for count in TOOL_COUNTS:
                for mode in MODES:
                    for run_idx in range(1, RUNS + 1):
                        for state in CACHE_STATES:
                            try:
                                row = await run_one(provider, mode, count, run_idx, state, client)
                            except Exception as e:
                                print(f"WARN: {provider}/{mode}-{count} run {run_idx} {state} failed: {e}")
                                continue
                            rows.append(row)
                            print(f"{provider}/{mode}-{count} run{run_idx} {state}: "
                                  f"first={row['first_call_prompt_tokens']} calls={row['llm_calls']} "
                                  f"cached={row['cached_tokens']} lat={row['latency_ms']:.0f}ms ok={row['task_ok']}")

    if not rows:
        print("No rows collected — nothing to write.")
        return

    (HERE / "results.json").write_text(json.dumps(rows, indent=2))
    with open(HERE / "results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)
    push_metrics(rows)
    print_summary(rows)

    for row in rows:
        exp = EXPECTED_TOOLS[row["mode"]]
        want = row["tool_count"] if exp is None else exp
        assert row["advertised_tools"] == want, \
            f"{row['mode']}-{row['tool_count']} advertised {row['advertised_tools']}, want {want}"


if __name__ == "__main__":
    asyncio.run(main())
