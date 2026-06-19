"""eval.py — orchestrator for the MCP progressive-disclosure evaluation framework.

Sweeps: provider × model × mode × persona × task × catalog_size × loop_k × sample.

Env knobs (all optional; defaults give a cheap smoke run):
  GATEWAY_URL       Gateway base URL            [http://localhost:8080]
  PUSHGATEWAY_URL   Prometheus pushgateway      [http://localhost:9091]

  -- scope selectors --
  PROVIDERS         comma-list                  [openai,anthropic]
  OPENAI_MODEL      override OpenAI model       [gpt-5.5]
  ANTHROPIC_MODEL   override Anthropic model    [claude-opus-4-8]
  MODES             comma-list                  [standard,search,codesearch]
  CATALOG_SIZES     comma-list (synthetic)      [5,10,15,30,50,100]
  PERSONAS          comma-list or "none"        [none]
  TASKS             comma-list of task IDs      [two_tools,single_echo]
  LOOP_KS           comma-list                  [0]   (0 = non-loop tasks only)
  SAMPLES           int; repeat each cell       [1]
  TARGETS           synthetic,rbac              [synthetic]
  MAX_TOOL_TURNS    max LLM→tool rounds         [8]

  -- output --
  RESULTS_CSV       output CSV path             [harness/results_v3.csv]
  RESULTS_JSON      output JSON path            [harness/results_v3.json]

Results CSV columns:
  provider,model,mode,persona,target,catalog_size,task_id,loop_k,sample,
  advertised_tools,first_call_prompt_tokens,total_prompt_tokens,
  completion_tokens,cached_tokens,cache_write_tokens,cache_read_tokens,
  total_tokens,llm_calls,latency_ms,usd_cost_uncached,usd_cost_cached,
  selected_tools,expected_tools,correct,task_ok
"""
from __future__ import annotations

import asyncio
import csv
import json
import os
import pathlib
import time
from typing import Any, Dict, List, Optional

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

from backends import (
    PROVIDERS, SYNTHETIC_CATALOG_SIZES, TOOL_SURFACE,
    get_provider, list_backends, build_real_backend,
    Backend, ProviderSpec,
)
from identities import PERSONAS, Persona, assert_rbac_subset
from metrics import usage_norm, cost, push_metrics
from tasks import get_task, make_loop_task, SMOKE_TASKS, Task

HERE = pathlib.Path(__file__).parent

# ---------------------------------------------------------------------------
# Env-driven sweep configuration
# ---------------------------------------------------------------------------

GATEWAY = os.environ.get("GATEWAY_URL", "http://localhost:8080")
PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "http://localhost:9091")

PROVIDERS_ENV = os.environ.get("PROVIDERS", "openai,anthropic").split(",")
MODES_ENV = os.environ.get("MODES", "standard,search,codesearch").split(",")
CATALOG_SIZES_ENV = [
    int(x) for x in os.environ.get("CATALOG_SIZES", "5,10,15,30,50,100").split(",")
]
PERSONAS_ENV = os.environ.get("PERSONAS", "none").split(",")
TASKS_ENV = os.environ.get("TASKS", ",".join(SMOKE_TASKS)).split(",")
LOOP_KS_ENV = [int(x) for x in os.environ.get("LOOP_KS", "0").split(",")]
SAMPLES = int(os.environ.get("SAMPLES", "1"))
TARGETS_ENV = os.environ.get("TARGETS", "synthetic").split(",")
MAX_TOOL_TURNS = int(os.environ.get("MAX_TOOL_TURNS", "8"))

RESULTS_CSV = os.environ.get("RESULTS_CSV", str(HERE / "results_v3.csv"))
RESULTS_JSON = os.environ.get("RESULTS_JSON", str(HERE / "results_v3.json"))

FIELDS = [
    "provider", "model", "mode", "persona", "target", "catalog_size",
    "task_id", "loop_k", "sample",
    "advertised_tools",
    "first_call_prompt_tokens", "total_prompt_tokens",
    "completion_tokens", "cached_tokens", "cache_write_tokens", "cache_read_tokens",
    "total_tokens", "llm_calls", "latency_ms",
    "usd_cost_uncached", "usd_cost_cached",
    "selected_tools", "expected_tools", "correct", "task_ok",
]


# ---------------------------------------------------------------------------
# MCP helpers
# ---------------------------------------------------------------------------

def mcp_tools_to_openai(tools) -> List[Dict[str, Any]]:
    """Convert MCP tool list to OpenAI function-calling schema."""
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


# ---------------------------------------------------------------------------
# Single-cell eval
# ---------------------------------------------------------------------------

async def run_cell(
    provider_spec: ProviderSpec,
    backend: Backend,
    task: Task,
    persona: Optional[Persona],
    sample_idx: int,
    client: httpx.AsyncClient,
) -> Dict[str, Any]:
    """Execute one (provider, backend, task, persona, sample) cell.

    Returns a result dict matching FIELDS.
    """
    llm_url = GATEWAY + provider_spec.route
    model = provider_spec.model
    loop_k = task.loop_steps

    # Merge persona headers into backend if applicable.
    active_backend = backend
    persona_name = "none"
    if persona is not None and persona.name != "none":
        active_backend = backend.with_persona_headers(persona.auth_header())
        persona_name = persona.name
    elif backend.target == "rbac":
        # the rbac server is JWT-gated; an unauthenticated call 401s. When no
        # persona is set, use the admin token so the cost sweep can still run.
        try:
            admin = PERSONAS["admin"]
            active_backend = backend.with_persona_headers(admin.auth_header())
        except (KeyError, FileNotFoundError):
            pass  # no token available; call will 401 and be recorded as a failed cell

    mcp_url = active_backend.mcp_url(GATEWAY)

    async with streamablehttp_client(mcp_url, headers=active_backend.headers) as (r, w, _):
        async with ClientSession(r, w) as session:
            await session.initialize()
            tools_list = (await session.list_tools()).tools
            openai_tools = mcp_tools_to_openai(tools_list)
            advertised_tools = len(tools_list)

            messages: List[Dict[str, Any]] = [{"role": "user", "content": task.prompt}]

            first_prompt: Optional[int] = None
            total_prompt = completion = cached = write = read = llm_calls = 0
            selected_tools: List[str] = []   # raw tool calls (incl. meta-tools)
            effective_tools: List[str] = []  # unwrapped upstream targets (for accuracy)
            expected = task.expected_tools

            t0 = time.perf_counter()

            for _turn in range(MAX_TOOL_TURNS):
                # Build request body; omit temperature for gpt-5.* models.
                body: Dict[str, Any] = {
                    "model": model,
                    "seed": 42,
                    "messages": messages,
                    "tools": openai_tools,
                }
                body.update(provider_spec.request_body_extras())

                resp_raw = await client.post(llm_url, json=body)
                resp = resp_raw.json()
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
                    if fn not in selected_tools:
                        selected_tools.append(fn)
                    args = json.loads(call["function"]["arguments"] or "{}")
                    # Unwrap meta-tools to the effective upstream tool, so accuracy
                    # is comparable across modes (search/code don't call tools directly).
                    if fn in ("invoke_tool", "get_tool"):
                        tgt = args.get("name") or args.get("tool") or args.get("tool_name")
                        if tgt and tgt not in effective_tools:
                            effective_tools.append(tgt)
                    elif fn == "run_code":
                        code = str(args.get("code", "") or args.get("source", ""))
                        for et in expected:           # detect referenced upstream tools
                            if et and et in code and et not in effective_tools:
                                effective_tools.append(et)
                    elif fn not in effective_tools:
                        effective_tools.append(fn)
                    try:
                        res = await session.call_tool(fn, arguments=args)
                        text = res.content[0].text if res.content else ""
                    except Exception as exc:
                        text = f"tool error: {exc}"
                    messages.append({
                        "role": "tool",
                        "tool_call_id": call["id"],
                        "content": text,
                    })

            latency_ms = (time.perf_counter() - t0) * 1000.0

            # Accuracy uses EFFECTIVE tools (meta-tools unwrapped), so search/code
            # are scored on the upstream tool they actually targeted.
            correct = bool(effective_tools and expected
                           and expected[0] in effective_tools)

            # task_ok: for deterministic tasks, check for known echo strings.
            blob = " ".join(
                str(m.get("content", "")) for m in messages
                if isinstance(m.get("content"), str)
            )
            # Default success heuristic: all expected tools were effectively invoked.
            if expected:
                task_ok = all(t in effective_tools for t in expected)
            else:
                task_ok = True

            # For the proven two-tool task, also require echo strings.
            if task.id == "two_tools":
                task_ok = (
                    "tool_003" in blob and "tool_005" in blob and "echoed" in blob
                )

    return {
        "provider": provider_spec.name,
        "model": model,
        "mode": backend.mode,
        "persona": persona_name,
        "target": backend.target,
        "catalog_size": backend.catalog_size,
        "task_id": task.id,
        "loop_k": loop_k,
        "sample": sample_idx,
        "advertised_tools": advertised_tools,
        "first_call_prompt_tokens": first_prompt or 0,
        "total_prompt_tokens": total_prompt,
        "completion_tokens": completion,
        "cached_tokens": cached,
        "cache_write_tokens": write,
        "cache_read_tokens": read,
        "total_tokens": total_prompt + completion,
        "llm_calls": llm_calls,
        "latency_ms": round(latency_ms, 1),
        "usd_cost_uncached": round(
            cost(model, total_prompt, completion, cached, write, read, False), 8
        ),
        "usd_cost_cached": round(
            cost(model, total_prompt, completion, cached, write, read, True), 8
        ),
        "selected_tools": ",".join(selected_tools),
        "expected_tools": ",".join(expected),
        "correct": correct,
        "task_ok": task_ok,
    }


# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

def _check_tool_surface(row: Dict[str, Any]) -> None:
    """Assert advertised tool count matches the expected surface for synthetic routes."""
    if row["target"] != "synthetic":
        return
    mode = row["mode"]
    catalog_size = int(row["catalog_size"])
    surface = TOOL_SURFACE.get(mode)
    want = catalog_size if surface is None else surface
    if want is not None:
        assert row["advertised_tools"] == want, (
            f"ASSERT FAIL {mode}-{catalog_size}: "
            f"advertised {row['advertised_tools']}, want {want}"
        )


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

async def main() -> None:
    rows: List[Dict[str, Any]] = []

    # Resolve backends.
    backends: List[Backend] = []
    for target in TARGETS_ENV:
        if target == "synthetic":
            backends.extend(
                list_backends(
                    targets=["synthetic"],
                    modes=MODES_ENV,
                    catalog_sizes=CATALOG_SIZES_ENV,
                )
            )
        elif target == "rbac":
            # Dedicated RBAC server (Standard mode, JWT-gated). One backend.
            try:
                backends.append(build_real_backend("rbac"))
            except ValueError:
                pass

    # Resolve tasks. (Empty TASKS= is valid — e.g. loop-only runs via LOOP_KS.)
    tasks: List[Task] = []
    for tid in TASKS_ENV:
        if not tid.strip():
            continue
        try:
            tasks.append(get_task(tid))
        except KeyError:
            print(f"WARN: unknown task '{tid}', skipping")
    for k in LOOP_KS_ENV:
        if k > 0:
            tasks.append(make_loop_task(k))

    # Resolve personas.
    personas: List[Optional[Persona]] = []
    for pname in PERSONAS_ENV:
        if pname == "none":
            personas.append(None)
        else:
            try:
                personas.append(PERSONAS[pname])
            except KeyError:
                print(f"WARN: unknown persona '{pname}', skipping")

    if not backends:
        print("No backends selected — check TARGETS/MODES/CATALOG_SIZES env vars.")
        return
    if not tasks:
        print("No tasks selected — check TASKS/LOOP_KS env vars.")
        return

    print(f"Sweep: {len(PROVIDERS_ENV)} providers × {len(backends)} backends × "
          f"{len(tasks)} tasks × {len(personas)} personas × {SAMPLES} samples")
    print(f"  Providers: {PROVIDERS_ENV}")
    print(f"  Backends:  {[(b.target, b.mode, b.catalog_size) for b in backends]}")
    print(f"  Tasks:     {[t.id for t in tasks]}")
    print(f"  Personas:  {[p.name if p else 'none' for p in personas]}")
    print()

    async with httpx.AsyncClient(timeout=180) as client:
        for provider_name in PROVIDERS_ENV:
            try:
                pspec = get_provider(provider_name)
            except KeyError as exc:
                print(f"WARN: {exc}, skipping")
                continue

            for backend in backends:
                for task in tasks:
                    # Skip loop tasks if loop_k > catalog_size (tools wouldn't exist).
                    if task.loop_steps > 0 and backend.catalog_size > 0:
                        if task.min_catalog_size > backend.catalog_size:
                            print(f"  SKIP {task.id}: needs catalog>={task.min_catalog_size}, "
                                  f"got {backend.catalog_size}")
                            continue

                    for persona in personas:
                        for sample in range(1, SAMPLES + 1):
                            label = (
                                f"{provider_name}/{backend.target}/{backend.mode}"
                                f"-{backend.catalog_size}/{task.id}"
                                f"/{persona.name if persona else 'none'}/s{sample}"
                            )
                            try:
                                row = await run_cell(
                                    pspec, backend, task, persona, sample, client
                                )
                            except Exception as exc:
                                print(f"  WARN: {label} failed: {exc}")
                                continue

                            rows.append(row)
                            print(
                                f"  {label}: "
                                f"adv={row['advertised_tools']} "
                                f"first={row['first_call_prompt_tokens']} "
                                f"calls={row['llm_calls']} "
                                f"cached={row['cached_tokens']} "
                                f"lat={row['latency_ms']:.0f}ms "
                                f"ok={row['task_ok']} "
                                f"correct={row['correct']}"
                            )

    if not rows:
        print("No rows collected — nothing to write.")
        return

    # Write results.
    pathlib.Path(RESULTS_JSON).write_text(json.dumps(rows, indent=2))
    with open(RESULTS_CSV, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)
    print(f"\nWrote {len(rows)} rows → {RESULTS_CSV}")
    print(f"Wrote JSON → {RESULTS_JSON}")

    push_metrics(rows)

    # Assertions: tool surface + RBAC subset.
    print("\n--- Assertions ---")
    assertion_failures: List[str] = []
    for row in rows:
        try:
            _check_tool_surface(row)
        except AssertionError as exc:
            assertion_failures.append(str(exc))
            print(f"  ASSERT FAIL: {exc}")

    # RBAC subset check: readonly ⊂ admin for the rbac server.
    if "readonly" in PERSONAS_ENV and "admin" in PERSONAS_ENV:
        for backend in backends:
            if backend.target == "rbac" and backend.mode == "standard":
                for provider_name in PROVIDERS_ENV:
                    for task in tasks:
                        ro_rows = [
                            r for r in rows
                            if r["provider"] == provider_name
                            and r["target"] == backend.target
                            and r["persona"] == "readonly"
                            and r["task_id"] == task.id
                        ]
                        admin_rows = [
                            r for r in rows
                            if r["provider"] == provider_name
                            and r["target"] == backend.target
                            and r["persona"] == "admin"
                            and r["task_id"] == task.id
                        ]
                        if ro_rows and admin_rows:
                            ro_tools = set(
                                t for r in ro_rows
                                for t in r["selected_tools"].split(",") if t
                            )
                            admin_tools = set(
                                t for r in admin_rows
                                for t in r["selected_tools"].split(",") if t
                            )
                            try:
                                assert_rbac_subset(
                                    list(ro_tools), list(admin_tools)
                                )
                            except AssertionError as exc:
                                assertion_failures.append(str(exc))
                                print(f"  RBAC FAIL: {exc}")

    if not assertion_failures:
        print("  All assertions passed.")
    else:
        print(f"  {len(assertion_failures)} assertion(s) failed.")

    # Summary.
    print("\n=== Summary ===")
    from collections import defaultdict
    summary: Dict[str, List] = defaultdict(list)
    for row in rows:
        key = f"{row['provider']}/{row['mode']}-{row['catalog_size']}"
        summary[key].append(row)
    for key, rs in sorted(summary.items()):
        n = len(rs)
        avg_first = sum(r["first_call_prompt_tokens"] for r in rs) / n
        avg_cost = sum(r["usd_cost_cached"] for r in rs) / n
        ok_rate = sum(1 for r in rs if r["task_ok"]) / n
        acc = sum(1 for r in rs if r["correct"]) / n
        print(f"  {key}: first={avg_first:.0f}tok cost=${avg_cost:.6f} "
              f"ok={ok_rate:.0%} acc={acc:.0%} n={n}")


if __name__ == "__main__":
    asyncio.run(main())
