"""Multi-turn GitHub conversation: ask 5 questions in ONE ongoing chat per tool
mode, and show how token cost COMPOUNDS across the conversation — plus real cache
reads.

Why this matters: in a real conversation the gateway re-sends the tool definitions
on every turn, and the whole accumulating transcript (full of GitHub JSON) is
re-processed each round-trip. Standard re-pays the full 28-tool catalog each turn;
Search sends 2 meta-tools but adds discovery round-trips. Over 5 turns those gaps
compound. gpt-5.5 also caches the stable prefix, so we capture cache_read tokens
and price them at the cached rate.

Prereqs: GitHub backends + proxy:8080 + pushgateway:9091. Backend gpt-5.5 → set
LLM_NO_TEMPERATURE=1.
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
MODES = {"standard": "/mcp/gh-std", "search": "/mcp/gh-search", "code": "/mcp/gh-code"}
IN = float(os.environ.get("IN_PER_1K", "0.005")) / 1000
CACHED_IN = float(os.environ.get("CACHED_IN_PER_1K", "0.0025")) / 1000   # ~50% off
OUT = float(os.environ.get("OUT_PER_1K", "0.015")) / 1000
MAX_SUBTURNS = 8

CONVERSATION = [
    "Who am I on GitHub — login, name, and public repo count?",
    "Now list my 5 most recently updated repositories.",
    "For the most recently updated one, show its 5 latest commits.",
    "Do I have any open pull requests or issues assigned to me right now?",
    "Summarize my current GitHub activity in a short status report.",
]


def to_openai(tools):
    return [{"type": "function", "function": {
        "name": t.name, "description": t.description or "",
        "parameters": t.inputSchema or {"type": "object", "properties": {}},
    }} for t in tools]


def no_temp():
    return os.environ.get("LLM_NO_TEMPERATURE", "").lower() in ("1", "true", "yes")


async def converse(path, client):
    """Run the whole 5-question conversation in one message thread. Returns a list
    of per-turn cumulative metrics."""
    async with streamablehttp_client(GW + path) as (r, w, _):
        async with ClientSession(r, w) as s:
            await s.initialize()
            ot = to_openai((await s.list_tools()).tools)
            messages = []
            cum_prompt = cum_cached = cum_completion = 0
            cum_cost = 0.0
            per_turn = []
            for turn, question in enumerate(CONVERSATION, 1):
                messages.append({"role": "user", "content": question})
                for _ in range(MAX_SUBTURNS):
                    body = {"model": "", "messages": messages, "tools": ot}
                    if not no_temp():
                        body["temperature"] = 0
                    resp = (await client.post(LLM, json=body)).json()
                    u = resp.get("usage", {})
                    p = u.get("prompt_tokens", 0)
                    cached = (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
                    comp = u.get("completion_tokens", 0)
                    cum_prompt += p
                    cum_cached += cached
                    cum_completion += comp
                    cum_cost += (p - cached) * IN + cached * CACHED_IN + comp * OUT
                    msg = resp["choices"][0]["message"]
                    messages.append(msg)
                    tcs = msg.get("tool_calls") or []
                    if not tcs:
                        break
                    for tc in tcs:
                        fn = tc["function"]["name"]
                        args = json.loads(tc["function"]["arguments"] or "{}")
                        try:
                            res = await s.call_tool(fn, arguments=args)
                            txt = res.content[0].text if res.content else ""
                        except Exception as e:
                            txt = f"tool error: {e}"
                        messages.append({"role": "tool", "tool_call_id": tc["id"], "content": txt[:3000]})
                per_turn.append({
                    "turn": turn, "cum_prompt": cum_prompt, "cum_cached": cum_cached,
                    "cum_total": cum_prompt + cum_completion, "cum_cost": cum_cost,
                })
            return per_turn


async def main():
    reg = CollectorRegistry()
    labels = ["mode", "turn"]
    g_prompt = Gauge("agw_ghconv_cum_prompt_tokens", "cumulative prompt tokens", labels, registry=reg)
    g_total = Gauge("agw_ghconv_cum_total_tokens", "cumulative total tokens", labels, registry=reg)
    g_cached = Gauge("agw_ghconv_cum_cached_tokens", "cumulative cache-read tokens", labels, registry=reg)
    g_cost = Gauge("agw_ghconv_cum_cost", "cumulative cache-aware USD", labels, registry=reg)

    async with httpx.AsyncClient(timeout=180) as client:
        results = {}
        for mode, path in MODES.items():
            print(f"\n=== {mode.upper()} — 5-question conversation ===")
            print(f"{'turn':>4}{'cum_prompt':>12}{'cum_cached':>12}{'cum_total':>11}{'cum_cost':>11}")
            per_turn = await converse(path, client)
            results[mode] = per_turn
            for t in per_turn:
                print(f"{t['turn']:>4}{t['cum_prompt']:>12}{t['cum_cached']:>12}{t['cum_total']:>11}{t['cum_cost']:>11.5f}")
                lbl = {"mode": mode, "turn": str(t["turn"])}
                g_prompt.labels(**lbl).set(t["cum_prompt"])
                g_total.labels(**lbl).set(t["cum_total"])
                g_cached.labels(**lbl).set(t["cum_cached"])
                g_cost.labels(**lbl).set(t["cum_cost"])

    if "standard" in results and "search" in results:
        ds = results["standard"][-1]["cum_cost"]
        ss = results["search"][-1]["cum_cost"]
        print(f"\nAfter 5 turns — cumulative cost: standard ${ds:.5f} vs search ${ss:.5f} "
              f"({(ds - ss) / ds * 100:.0f}% less); cache reads (standard) "
              f"{results['standard'][-1]['cum_cached']} tokens.")

    try:
        delete_from_gateway(PUSHGATEWAY, job="agw_gh_conversation")
    except Exception:
        pass
    try:
        push_to_gateway(PUSHGATEWAY, job="agw_gh_conversation", registry=reg)
        print(f"Pushed conversation metrics to {PUSHGATEWAY}")
    except Exception as e:
        print(f"WARN: could not push ({e})")


if __name__ == "__main__":
    asyncio.run(main())
