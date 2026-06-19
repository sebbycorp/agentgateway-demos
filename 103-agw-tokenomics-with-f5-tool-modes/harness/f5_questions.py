"""Ask the F5 a fixed set of 5 questions through each tool mode and push the
results to Prometheus so Grafana can chart them (dashboard-f5.json).

For each (question x mode) it records: tools advertised, first-call tool tokens,
total tokens, LLM round-trips, USD cost, and whether the task completed.

Prereqs: F5 backends deployed (k8s/f5.yaml) + proxy port-forwarded to :8080 +
pushgateway port-forwarded to :9091. Backend on gpt-5.5 → set LLM_NO_TEMPERATURE=1.
"""
import asyncio
import json
import os

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from prometheus_client import CollectorRegistry, Gauge, delete_from_gateway, push_to_gateway

GW = os.environ.get("GATEWAY_URL", "http://localhost:8080")
PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "http://localhost:9091")
LLM = GW + "/openai"
MODES = {"standard": "/mcp/real-f5-std", "search": "/mcp/real-f5-search", "code": "/mcp/real-f5-code"}
# gpt-5.5 list-price estimate (USD per token); override via env if needed.
IN_PER_TOK = float(os.environ.get("IN_PER_1K", "0.005")) / 1000
OUT_PER_TOK = float(os.environ.get("OUT_PER_1K", "0.015")) / 1000
NO_TEMP = bool(os.environ.get("LLM_NO_TEMPERATURE"))
MAX_TURNS = 10

# 5 read-only questions an operator would actually ask the F5.
QUESTIONS = [
    ("pools",     "How many LTM pools are in the Common partition, and list their names?"),
    ("virtuals",  "List the LTM virtual servers and their destinations."),
    ("system",    "What is the BIG-IP version, hostname, and platform?"),
    ("failover",  "What is the HA failover status of this BIG-IP?"),
    ("certs",     "List the SSL certificates and their expiration dates."),
]


def to_openai(tools):
    return [{"type": "function", "function": {
        "name": t.name, "description": t.description or "",
        "parameters": t.inputSchema or {"type": "object", "properties": {}},
    }} for t in tools]


async def run(path, question, client):
    async with streamablehttp_client(GW + path) as (r, w, _):
        async with ClientSession(r, w) as s:
            await s.initialize()
            tools = (await s.list_tools()).tools
            ot = to_openai(tools)
            msgs = [{"role": "user", "content": question}]
            first = None
            total_prompt = completion = calls = 0
            answered = False
            for _ in range(MAX_TURNS):
                body = {"model": "", "messages": msgs, "tools": ot}
                if not NO_TEMP:
                    body["temperature"] = 0
                resp = (await client.post(LLM, json=body)).json()
                calls += 1
                u = resp.get("usage", {})
                p = u.get("prompt_tokens", 0)
                total_prompt += p
                completion += u.get("completion_tokens", 0)
                first = first if first is not None else p
                msg = resp["choices"][0]["message"]
                msgs.append(msg)
                tcs = msg.get("tool_calls") or []
                if not tcs:
                    answered = bool(msg.get("content"))
                    break
                for tc in tcs:
                    fn = tc["function"]["name"]
                    args = json.loads(tc["function"]["arguments"] or "{}")
                    try:
                        res = await s.call_tool(fn, arguments=args)
                        text = res.content[0].text if res.content else ""
                    except Exception as e:
                        text = f"tool error: {e}"
                    msgs.append({"role": "tool", "tool_call_id": tc["id"], "content": text[:4000]})
            cost = total_prompt * IN_PER_TOK + completion * OUT_PER_TOK
            return {
                "advertised": len(tools), "first": first or 0, "total": total_prompt + completion,
                "calls": calls, "cost": cost, "ok": answered,
            }


async def main():
    reg = CollectorRegistry()
    labels = ["question", "mode"]
    g_first = Gauge("agw_f5q_first_call_tokens", "first-call tool tokens", labels, registry=reg)
    g_total = Gauge("agw_f5q_total_tokens", "total tokens per task", labels, registry=reg)
    g_calls = Gauge("agw_f5q_llm_calls", "LLM round-trips", labels, registry=reg)
    g_cost = Gauge("agw_f5q_usd_cost", "USD cost per task", labels, registry=reg)
    g_ok = Gauge("agw_f5q_task_ok", "task answered", labels, registry=reg)
    g_adv = Gauge("agw_f5q_advertised_tools", "tools advertised", labels, registry=reg)

    async with httpx.AsyncClient(timeout=120) as client:
        print(f"{'question':<10}{'mode':<10}{'adv':>5}{'first':>8}{'total':>8}{'calls':>7}{'cost':>11}{'ok':>5}")
        for qid, qtext in QUESTIONS:
            for mode, path in MODES.items():
                try:
                    m = await run(path, qtext, client)
                except Exception as e:
                    print(f"{qid:<10}{mode:<10}  ERROR {type(e).__name__}: {str(e)[:50]}")
                    continue
                print(f"{qid:<10}{mode:<10}{m['advertised']:>5}{m['first']:>8}{m['total']:>8}"
                      f"{m['calls']:>7}{m['cost']:>11.5f}{('Y' if m['ok'] else 'n'):>5}")
                lbl = {"question": qid, "mode": mode}
                g_first.labels(**lbl).set(m["first"])
                g_total.labels(**lbl).set(m["total"])
                g_calls.labels(**lbl).set(m["calls"])
                g_cost.labels(**lbl).set(m["cost"])
                g_ok.labels(**lbl).set(1 if m["ok"] else 0)
                g_adv.labels(**lbl).set(m["advertised"])

    try:
        delete_from_gateway(PUSHGATEWAY, job="agw_f5_questions")
    except Exception:
        pass
    try:
        push_to_gateway(PUSHGATEWAY, job="agw_f5_questions", registry=reg)
        print(f"\nPushed F5 question metrics to {PUSHGATEWAY}")
    except Exception as e:
        print(f"\nWARN: could not push ({e})")


if __name__ == "__main__":
    asyncio.run(main())
