"""Ask GitHub a fixed set of 5 questions through each tool mode and push the
results to Prometheus so Grafana can chart them.

For each (question x mode) it records: tools advertised, first-call tool tokens,
total tokens, cache-read tokens, LLM round-trips, USD cost, and whether the task
completed. The MCP server is GitHub's external remote MCP, fronted by the gateway
in Standard / Search / Code mode and pinned to the read-only surface.

Prereqs: GitHub backends deployed (k8s/github.yaml) + proxy port-forwarded to
:8080 + pushgateway port-forwarded to :9091. Backend on gpt-5.5 → set
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
# Headroom knob: when HEADROOM=on, LLM_URL points at the local Headroom proxy
# (which forwards to AGW /openai after compressing the request body). Default =
# straight to AGW /openai (Headroom OFF). AGW's tool-mode (catalog) effect is
# independent of this URL: the catalog is baked into the request body here from
# MCP tools/list, not added by the /openai route — so the two knobs stay orthogonal.
LLM = os.environ.get("LLM_URL", GW + "/openai")
HEADROOM = os.environ.get("HEADROOM", "off").lower() in ("1", "on", "true", "yes")
HR = "on" if HEADROOM else "off"
JOB = os.environ.get("PUSH_JOB", "agw_hr_questions")
RESULTS_FILE = os.environ.get("RESULTS_FILE", "results.jsonl")
MODES = {"standard": "/mcp/gh-std", "search": "/mcp/gh-search", "code": "/mcp/gh-code"}
# gpt-5.5 list-price estimate (USD per token); override via env if needed.
IN_PER_TOK = float(os.environ.get("IN_PER_1K", "0.005")) / 1000
CACHED_PER_TOK = float(os.environ.get("CACHED_IN_PER_1K", "0.0025")) / 1000  # ~50% off
OUT_PER_TOK = float(os.environ.get("OUT_PER_1K", "0.015")) / 1000
NO_TEMP = bool(os.environ.get("LLM_NO_TEMPERATURE"))
MAX_TURNS = 10

# All questions are pinned to ONE dedicated sandbox repo so the test can never
# touch anything else. For a hard guarantee, also use a fine-grained read-only PAT
# scoped to only this repo (see README).
REPO = os.environ.get("GH_REPO", "sebbycorp/agw-tokenomics-sandbox")
SYSTEM = (f"You are a read-only GitHub assistant. You may ONLY access the repository "
          f"{REPO}. Never query, search, or reference any other repository or the "
          f"user's other repositories. If a request would require another repo, refuse.")

# 5 read-only questions, all scoped to the single sandbox repo.
QUESTIONS = [
    ("repo",     f"Describe the repository {REPO}: its description, default branch, and primary language."),
    ("commits",  f"List the 5 most recent commits on {REPO} with their messages."),
    ("issues",   f"List the open issues in {REPO} with their titles."),
    ("prs",      f"List the open pull requests in {REPO} with their titles."),
    ("contents", f"List the files in the src/ directory of {REPO}."),
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
            msgs = [{"role": "system", "content": SYSTEM},
                    {"role": "user", "content": question}]
            first = None
            total_prompt = completion = cached = calls = 0
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
                cached += (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
                first = first if first is not None else p
                msg = resp["choices"][0]["message"]
                msgs.append(msg)
                tcs = msg.get("tool_calls") or []
                if not tcs:
                    answer = msg.get("content") or ""
                    answered = bool(answer)
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
            else:
                answer = ""
            cost = (total_prompt - cached) * IN_PER_TOK + cached * CACHED_PER_TOK + completion * OUT_PER_TOK
            return {
                "advertised": len(tools), "first": first or 0, "total": total_prompt + completion,
                "cached": cached, "calls": calls, "cost": cost, "ok": answered,
                "answer": answer,
            }


async def main():
    reg = CollectorRegistry()
    labels = ["question", "mode", "headroom", "repo"]
    g_first = Gauge("agw_hr_first_call_tokens", "first-call tool tokens", labels, registry=reg)
    g_total = Gauge("agw_hr_total_tokens", "total tokens per task", labels, registry=reg)
    g_calls = Gauge("agw_hr_llm_calls", "LLM round-trips", labels, registry=reg)
    g_cost = Gauge("agw_hr_usd_cost", "USD cost per task", labels, registry=reg)
    g_ok = Gauge("agw_hr_task_ok", "task answered", labels, registry=reg)
    g_adv = Gauge("agw_hr_advertised_tools", "tools advertised", labels, registry=reg)
    g_cached = Gauge("agw_hr_cached_tokens", "cache-read tokens per task", labels, registry=reg)

    print(f"# repo={REPO}  headroom={HR}  llm={LLM}")
    async with httpx.AsyncClient(timeout=120) as client, open(RESULTS_FILE, "a") as out:
        print(f"{'question':<10}{'mode':<10}{'adv':>5}{'first':>8}{'total':>8}{'cached':>8}{'calls':>7}{'cost':>11}{'ok':>5}")
        for qid, qtext in QUESTIONS:
            for mode, path in MODES.items():
                try:
                    m = await run(path, qtext, client)
                except Exception as e:
                    print(f"{qid:<10}{mode:<10}  ERROR {type(e).__name__}: {str(e)[:50]}")
                    continue
                print(f"{qid:<10}{mode:<10}{m['advertised']:>5}{m['first']:>8}{m['total']:>8}"
                      f"{m['cached']:>8}{m['calls']:>7}{m['cost']:>11.5f}{('Y' if m['ok'] else 'n'):>5}")
                lbl = {"question": qid, "mode": mode, "headroom": HR, "repo": REPO}
                g_first.labels(**lbl).set(m["first"])
                g_total.labels(**lbl).set(m["total"])
                g_calls.labels(**lbl).set(m["calls"])
                g_cost.labels(**lbl).set(m["cost"])
                g_ok.labels(**lbl).set(1 if m["ok"] else 0)
                g_adv.labels(**lbl).set(m["advertised"])
                g_cached.labels(**lbl).set(m["cached"])
                # Persist one JSON line per cell so judge.py can score answers and
                # so every answer is auditable. The judge baseline is the
                # standard / headroom=off row for this (repo, question).
                out.write(json.dumps({
                    "repo": REPO, "headroom": HR, "question": qid, "mode": mode,
                    "cost": m["cost"], "total": m["total"], "first": m["first"],
                    "calls": m["calls"], "ok": m["ok"], "answer": m.get("answer", ""),
                }) + "\n")
                out.flush()

    # Push grouped per (headroom, repo) so OFF/ON and small/large runs don't
    # overwrite each other (delete_from_gateway wipes the whole grouping).
    job = f"{JOB}_{HR}_{REPO.replace('/', '_')}"
    try:
        delete_from_gateway(PUSHGATEWAY, job=job)
    except Exception:
        pass
    try:
        push_to_gateway(PUSHGATEWAY, job=job, registry=reg)
        print(f"\nPushed GitHub question metrics to {PUSHGATEWAY} (job={job})")
    except Exception as e:
        print(f"\nWARN: could not push ({e})")


if __name__ == "__main__":
    asyncio.run(main())
