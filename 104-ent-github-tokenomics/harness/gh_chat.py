"""Interactive LLM chat against your GitHub (via the external remote MCP server),
through a chosen MCP tool mode.

Ask a question in plain English; an LLM (via the gateway /openai route) answers it
by using the GitHub tools exposed in the selected mode, and you see exactly which
tools were called plus the token cost. The gateway pins the upstream to GitHub's
read-only MCP surface, so nothing can mutate your repos.

Modes (see https://docs.solo.io/agentgateway/latest/mcp/tool-mode/):
  standard  — all 28 read-only GitHub tools advertised; model calls them directly
  search    — model sees get_tool + invoke_tool; discovers + calls on demand
  code      — model sees run_code; writes JavaScript that calls GitHub tools in a sandbox

Usage:
  ./.venv/bin/python gh_chat.py search                       # interactive prompt loop
  ./.venv/bin/python gh_chat.py code "list my repos"         # one-shot
Prereqs: GitHub backends deployed (k8s/github.yaml) + proxy port-forwarded to :8080.
"""
import asyncio
import json
import os
import sys

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

GW = os.environ.get("GATEWAY_URL", "http://localhost:8080")
LLM = GW + "/openai"
ROUTES = {"standard": "/mcp/gh-std", "search": "/mcp/gh-search", "code": "/mcp/gh-code"}
# gpt-5.5 list-price estimate (USD per token); override via env if needed.
IN_PER_TOK = float(os.environ.get("IN_PER_1K", "0.005")) / 1000
OUT_PER_TOK = float(os.environ.get("OUT_PER_1K", "0.015")) / 1000
MAX_TURNS = 8


def to_openai(tools):
    return [{
        "type": "function",
        "function": {
            "name": t.name,
            "description": t.description or "",
            "parameters": t.inputSchema or {"type": "object", "properties": {}},
        },
    } for t in tools]


def short(v, n=160):
    s = v if isinstance(v, str) else json.dumps(v)
    return s if len(s) <= n else s[:n] + "…"


async def ask(session, openai_tools, question, client):
    messages = [{"role": "user", "content": question}]
    first = None
    total_prompt = completion = calls = 0
    while calls < MAX_TURNS:
        body = {"model": "", "messages": messages, "tools": openai_tools}
        # gpt-5.* (this demo's backend) rejects temperature != 1; omit it when
        # LLM_NO_TEMPERATURE is truthy. Set LLM_NO_TEMPERATURE=0 for models that allow 0.
        if os.environ.get("LLM_NO_TEMPERATURE", "").lower() not in ("1", "true", "yes"):
            body["temperature"] = 0
        resp = (await client.post(LLM, json=body)).json()
        calls += 1
        u = resp.get("usage", {})
        p = u.get("prompt_tokens", 0)
        total_prompt += p
        completion += u.get("completion_tokens", 0)
        first = first or p
        msg = resp["choices"][0]["message"]
        messages.append(msg)
        tool_calls = msg.get("tool_calls") or []
        if not tool_calls:
            print(f"\n🟢 answer: {msg.get('content','')}\n")
            break
        for tc in tool_calls:
            fn = tc["function"]["name"]
            args = json.loads(tc["function"]["arguments"] or "{}")
            print(f"  → tool call: {fn}({short(args, 120)})")
            try:
                res = await session.call_tool(fn, arguments=args)
                text = res.content[0].text if res.content else ""
            except Exception as e:
                text = f"tool error: {e}"
            print(f"     ↳ result: {short(text, 160)}")
            messages.append({"role": "tool", "tool_call_id": tc["id"], "content": text[:4000]})
    cost = total_prompt * IN_PER_TOK + completion * OUT_PER_TOK
    print(f"  📊 first-call tool tokens={first}  total_prompt={total_prompt}  "
          f"llm_calls={calls}  cost=${cost:.6f}")


async def main():
    mode = (sys.argv[1] if len(sys.argv) > 1 else "search").lower()
    if mode not in ROUTES:
        print(f"mode must be one of {list(ROUTES)}"); return
    one_shot = " ".join(sys.argv[2:]).strip() or None
    route = ROUTES[mode]
    async with httpx.AsyncClient(timeout=120) as client:
        async with streamablehttp_client(GW + route) as (r, w, _):
            async with ClientSession(r, w) as session:
                await session.initialize()
                tools = (await session.list_tools()).tools
                openai_tools = to_openai(tools)
                print(f"\n=== GitHub via {mode.upper()} mode ({route}) ===")
                print(f"Tools advertised to the model: {len(tools)} "
                      f"({', '.join(t.name for t in tools)})\n")
                if one_shot:
                    print(f"❓ {one_shot}")
                    await ask(session, openai_tools, one_shot, client)
                    return
                print("Ask GitHub a question (or 'quit'):")
                while True:
                    try:
                        q = input("\n❓ > ").strip()
                    except (EOFError, KeyboardInterrupt):
                        print(); break
                    if q.lower() in ("quit", "exit", "q", ""):
                        break
                    await ask(session, openai_tools, q, client)


if __name__ == "__main__":
    asyncio.run(main())
