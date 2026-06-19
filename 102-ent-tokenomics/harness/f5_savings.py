"""Measure Search-mode token savings on the REAL F5 MCP server.

Runs the same F5 task through Standard mode (all 29 tools advertised) and Search
mode (get_tool + invoke_tool), via gpt-4o-mini through the gateway, and reports
first-call tool-definition tokens, total prompt tokens, round-trips, and USD cost.

Prereqs: deploy the F5 wrapper + real-f5-std / real-f5-search backends (k8s/f5.yaml),
port-forward the proxy to :8080. Override the task with F5_TASK, model with
OPENAI_MODEL_ID.
"""
import asyncio
import json
import os

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

GW = os.environ.get("GATEWAY_URL", "http://localhost:8080")
LLM = GW + "/openai"
TASK = os.environ.get(
    "F5_TASK",
    "List all the LTM pools on the F5 BIG-IP (Common partition). "
    "Use the available tools, then summarize what you find.",
)
# gpt-4o-mini list price per token (the demo's cheap measurement model).
IN_PER_TOK = 0.00015 / 1000
OUT_PER_TOK = 0.0006 / 1000
MAX_TURNS = 6


def to_openai(tools):
    return [{
        "type": "function",
        "function": {
            "name": t.name,
            "description": t.description or "",
            "parameters": t.inputSchema or {"type": "object", "properties": {}},
        },
    } for t in tools]


async def run(path, client):
    async with streamablehttp_client(GW + path) as (r, w, _):
        async with ClientSession(r, w) as s:
            await s.initialize()
            tools = (await s.list_tools()).tools
            ot = to_openai(tools)
            msgs = [{"role": "user", "content": TASK}]
            first = None
            total_prompt = completion = calls = 0
            for _ in range(MAX_TURNS):
                resp = (await client.post(LLM, json={
                    "model": "", "temperature": 0, "messages": msgs, "tools": ot,
                })).json()
                calls += 1
                u = resp.get("usage", {})
                p = u.get("prompt_tokens", 0)
                total_prompt += p
                completion += u.get("completion_tokens", 0)
                first = first or p
                ch = resp["choices"][0]["message"]
                msgs.append(ch)
                tcs = ch.get("tool_calls") or []
                if not tcs:
                    break
                for c in tcs:
                    fn = c["function"]["name"]
                    args = json.loads(c["function"]["arguments"] or "{}")
                    try:
                        res = await s.call_tool(fn, arguments=args)
                        txt = res.content[0].text if res.content else ""
                    except Exception as e:
                        txt = f"tool error: {e}"
                    msgs.append({"role": "tool", "tool_call_id": c["id"], "content": txt[:1500]})
            cost = total_prompt * IN_PER_TOK + completion * OUT_PER_TOK
            return len(tools), first or 0, total_prompt, calls, cost


async def main():
    async with httpx.AsyncClient(timeout=120) as c:
        print(f"{'mode':<10}{'adv_tools':>10}{'first_tok':>11}{'total_prompt':>13}{'llm_calls':>10}{'usd_cost':>11}")
        res = {}
        for mode, path in [("standard", "/mcp/real-f5-std"), ("search", "/mcp/real-f5-search")]:
            adv, first, tp, calls, cost = await run(path, c)
            res[mode] = (first, cost)
            print(f"{mode:<10}{adv:>10}{first:>11}{tp:>13}{calls:>10}{cost:>11.6f}")
        sf, sc = res["search"]
        df, dc = res["standard"]
        print(f"\nSearch vs Standard — first-call tool tokens: {df} -> {sf}  ({(df - sf) / df * 100:.1f}% less)")
        print(f"Search vs Standard — task cost: ${dc:.6f} -> ${sc:.6f}  ({(dc - sc) / dc * 100:.1f}% less)")


if __name__ == "__main__":
    asyncio.run(main())
