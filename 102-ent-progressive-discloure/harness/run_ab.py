"""A/B harness proving MCP search mode reduces prompt tokens vs default mode.

For each (mode x tool_count) it connects to the gateway MCP route, lists the
advertised tools, runs an identical task through gpt-4o-mini (via the gateway
/openai route), executes any tool calls back through MCP, and records token
usage + USD cost. Results -> CSV/JSON + Prometheus Pushgateway gauges.
"""
import asyncio
import csv
import json
import os
import pathlib

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

GATEWAY = os.environ.get("GATEWAY_URL", "http://localhost:8080")
LLM_URL = os.environ.get("LLM_URL", f"{GATEWAY}/openai")
PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "http://localhost:9091")
RUNS = int(os.environ.get("RUNS", "5"))
TOOL_COUNTS = [int(x) for x in os.environ.get("TOOL_COUNTS", "10,50,100").split(",")]
MODEL = "gpt-4o-mini"
TASK = (
    "Call the tool named tool_007 with text='hello', number=42, flag=true. "
    "Then reply with exactly the tool's returned string and nothing else."
)
HERE = pathlib.Path(__file__).parent
PRICING = json.loads((HERE / "pricing.json").read_text())[MODEL]


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


def cost_usd(prompt_tokens, completion_tokens):
    return (prompt_tokens / 1000.0) * PRICING["input_per_1k"] + \
           (completion_tokens / 1000.0) * PRICING["output_per_1k"]


async def run_one(mode, count, run_idx, client):
    path = f"/mcp/{mode}-{count}"
    async with streamablehttp_client(f"{GATEWAY}{path}") as (r, w, _):
        async with ClientSession(r, w) as session:
            await session.initialize()
            listed = await session.list_tools()
            tools = listed.tools
            openai_tools = mcp_tools_to_openai(tools)

            messages = [{"role": "user", "content": TASK}]
            first_prompt = None
            total_prompt = completion = 0
            task_ok = False

            for _ in range(6):  # bounded tool loop
                resp = (await client.post(LLM_URL, json={
                    "model": "", "temperature": 0, "seed": 42,
                    "messages": messages, "tools": openai_tools,
                })).json()
                usage = resp.get("usage", {})
                p = usage.get("prompt_tokens", 0)
                completion += usage.get("completion_tokens", 0)
                total_prompt += p
                if first_prompt is None:
                    first_prompt = p

                choice = resp["choices"][0]["message"]
                messages.append(choice)
                calls = choice.get("tool_calls") or []
                if not calls:
                    if "tool_007 echoed" in (choice.get("content") or ""):
                        task_ok = True
                    break
                for call in calls:
                    fn = call["function"]["name"]
                    args = json.loads(call["function"]["arguments"] or "{}")
                    result = await session.call_tool(fn, arguments=args)
                    text = result.content[0].text if result.content else ""
                    if "tool_007 echoed" in text:
                        task_ok = True
                    messages.append({
                        "role": "tool", "tool_call_id": call["id"], "content": text,
                    })

            if not task_ok:
                print(f"WARN: {mode}-{count} run {run_idx} did not confirm task "
                      f"completion (tool-loop limit reached or no echo seen)")

            return {
                "mode": mode, "tool_count": count, "run": run_idx,
                "advertised_tools": len(tools),
                "first_call_prompt_tokens": first_prompt or 0,
                "total_prompt_tokens": total_prompt,
                "completion_tokens": completion,
                "total_tokens": total_prompt + completion,
                "usd_cost": round(cost_usd(total_prompt, completion), 8),
                "task_ok": task_ok,
            }


def push_metrics(rows):
    reg = CollectorRegistry()
    g_first = Gauge("agw_first_call_prompt_tokens", "avg first-call prompt tokens",
                    ["mode", "tool_count"], registry=reg)
    g_total = Gauge("agw_total_tokens", "avg total tokens", ["mode", "tool_count"], registry=reg)
    g_cost = Gauge("agw_usd_cost", "avg USD cost per task", ["mode", "tool_count"], registry=reg)
    g_adv = Gauge("agw_advertised_tools", "tools advertised", ["mode", "tool_count"], registry=reg)
    agg = {}
    for row in rows:
        k = (row["mode"], row["tool_count"])
        agg.setdefault(k, []).append(row)
    for (mode, count), rs in agg.items():
        n = len(rs)
        lbl = {"mode": mode, "tool_count": str(count)}
        g_first.labels(**lbl).set(sum(r["first_call_prompt_tokens"] for r in rs) / n)
        g_total.labels(**lbl).set(sum(r["total_tokens"] for r in rs) / n)
        g_cost.labels(**lbl).set(sum(r["usd_cost"] for r in rs) / n)
        g_adv.labels(**lbl).set(rs[0]["advertised_tools"])
    try:
        push_to_gateway(PUSHGATEWAY, job="agw_progressive_disclosure", registry=reg)
        print(f"Pushed metrics to {PUSHGATEWAY}")
    except Exception as e:
        print(f"WARN: could not push to pushgateway ({e}); CSV/JSON still written")


def print_summary(rows):
    print("\n=== Search-mode savings summary ===")
    agg = {}
    for row in rows:
        k = (row["tool_count"], row["mode"])
        agg.setdefault(k, []).append(row["first_call_prompt_tokens"])
    for count in sorted({r["tool_count"] for r in rows}):
        d = sum(agg[(count, "default")]) / len(agg[(count, "default")])
        s = sum(agg[(count, "search")]) / len(agg[(count, "search")])
        pct = (d - s) / d * 100 if d else 0
        print(f"  {count:>3} tools: default {d:8.0f} tok -> search {s:6.0f} tok "
              f"= {pct:5.1f}% reduction")


async def main():
    rows = []
    async with httpx.AsyncClient(timeout=60) as client:
        for count in TOOL_COUNTS:
            for mode in ("default", "search"):
                for run_idx in range(1, RUNS + 1):
                    row = await run_one(mode, count, run_idx, client)
                    rows.append(row)
                    print(f"{mode}-{count} run {run_idx}: "
                          f"first_prompt={row['first_call_prompt_tokens']} ok={row['task_ok']}")

    if not rows:
        print("No rows collected — nothing to write.")
        return

    (HERE / "results.json").write_text(json.dumps(rows, indent=2))
    with open(HERE / "results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    push_metrics(rows)
    print_summary(rows)

    # sanity assertions
    for row in rows:
        if row["mode"] == "search":
            assert row["advertised_tools"] == 2, f"search advertised {row['advertised_tools']}"
        else:
            assert row["advertised_tools"] == row["tool_count"], "default tool count mismatch"


if __name__ == "__main__":
    asyncio.run(main())
