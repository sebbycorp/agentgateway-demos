"""Generate dashboard-github.json (GitHub tool-modes Grafana dashboard) with the
embedded agentgateway logo. Run:  python3 build_dashboard.py
Metrics come from harness/gh_questions.py (job=agw_gh_questions) and
harness/gh_conversation.py (job=agw_gh_conversation)."""
import base64
import json
import pathlib

HERE = pathlib.Path(__file__).parent
b64 = base64.b64encode((HERE / "logo.svg").read_bytes()).decode()
logo_uri = f"data:image/svg+xml;base64,{b64}"


def stat(id, title, desc, x, y, w, expr, color=None, unit=None, pct=False, dec=0):
    fc = {"defaults": {}}
    if unit:
        fc["defaults"]["unit"] = unit
    if color:
        fc["defaults"]["color"] = {"mode": "fixed", "fixedColor": color}
    fc["defaults"]["decimals"] = dec
    return {"id": id, "type": "stat", "title": title, "description": desc,
            "gridPos": {"h": 6, "w": w, "x": x, "y": y}, "fieldConfig": fc,
            "targets": [{"expr": expr}]}


def bars(id, title, desc, x, y, w, h, targets, unit="short", dec=0):
    return {"id": id, "type": "bargauge", "title": title, "description": desc,
            "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "options": {"orientation": "horizontal", "displayMode": "gradient"},
            "fieldConfig": {"defaults": {"unit": unit, "decimals": dec}},
            "targets": targets}


panels = [
    {"id": 9000, "type": "text", "title": "", "transparent": True,
     "gridPos": {"h": 3, "w": 24, "x": 0, "y": 0},
     "options": {"mode": "html",
                 "content": f'<div style="display:flex;align-items:center;height:100%">'
                            f'<img src="{logo_uri}" style="height:46px"/>'
                            f'<span style="margin-left:16px;font-size:20px;color:#b9b3c7">'
                            f'GitHub (external MCP) via tool modes</span></div>'}},

    stat(1, "Avg first-call tool tokens — STANDARD", "All 28 read-only GitHub tools sent to the model every call.",
         0, 3, 8, 'avg(agw_ghq_first_call_tokens{mode="standard"})', color="red"),
    stat(2, "Avg first-call tool tokens — SEARCH", "Only get_tool + invoke_tool sent; the model discovers tools on demand.",
         8, 3, 8, 'avg(agw_ghq_first_call_tokens{mode="search"})', color="green"),
    stat(3, "Tool-context reduction (Search vs Standard)", "How much smaller the per-call GitHub tool context is with Search mode.",
         16, 3, 8, '(1 - avg(agw_ghq_first_call_tokens{mode="search"}) / avg(agw_ghq_first_call_tokens{mode="standard"})) * 100',
         unit="percent"),

    stat(4, "Tools advertised — Standard (full GitHub catalog)", "GitHub tools the model sees in Standard mode (Search=2, Code=1 — see the by-mode bar panel).",
         0, 9, 8, 'avg(agw_ghq_advertised_tools{mode="standard"})', color="red"),
    stat(5, "Questions answered successfully", "Share of the 5 GitHub questions completed across all modes.",
         8, 9, 8, 'avg(agw_ghq_task_ok) * 100', unit="percent"),
    stat(6, "Avg cost per task — Code", "Average USD per GitHub question in Code mode (gpt-5.5 list-price estimate) — the overall winner here.",
         16, 9, 8, 'avg(agw_ghq_usd_cost{mode="code"})', unit="currencyUSD", color="green", dec=4),

    bars(10, "First-call tool tokens by question, by mode", "Per GitHub question: tool-definition tokens the model carries. Standard (28 tools) vs Search (2) vs Code (1). Shorter is better.",
         0, 15, 12, 9,
         [{"expr": 'agw_ghq_first_call_tokens{mode="standard"}', "legendFormat": "{{question}} — standard"},
          {"expr": 'agw_ghq_first_call_tokens{mode="search"}', "legendFormat": "{{question}} — search"},
          {"expr": 'agw_ghq_first_call_tokens{mode="code"}', "legendFormat": "{{question}} — code"}]),
    bars(11, "Tools advertised to the model, by mode", "Standard exposes the full GitHub catalog; Search and Code keep it tiny.",
         12, 15, 12, 9,
         [{"expr": 'avg by (mode) (agw_ghq_advertised_tools)', "legendFormat": "{{mode}}"}]),

    bars(12, "Total tokens per question, by mode (the full picture)", "Total prompt+completion tokens incl. the extra Search/Code round-trips. The 'prs' question explodes in Standard; Code stays flat.",
         0, 24, 12, 9,
         [{"expr": 'agw_ghq_total_tokens{mode="standard"}', "legendFormat": "{{question}} — standard"},
          {"expr": 'agw_ghq_total_tokens{mode="search"}', "legendFormat": "{{question}} — search"},
          {"expr": 'agw_ghq_total_tokens{mode="code"}', "legendFormat": "{{question}} — code"}]),
    bars(13, "Cost per task by question & mode", "USD per GitHub question by mode (gpt-5.5 list-price estimate). Code is cheapest on 4 of 5.",
         12, 24, 12, 9,
         [{"expr": 'agw_ghq_usd_cost{mode="standard"}', "legendFormat": "{{question}} — standard"},
          {"expr": 'agw_ghq_usd_cost{mode="search"}', "legendFormat": "{{question}} — search"},
          {"expr": 'agw_ghq_usd_cost{mode="code"}', "legendFormat": "{{question}} — code"}],
         unit="currencyUSD", dec=5),

    # ----- Multi-turn conversation row (from harness/gh_conversation.py) -----
    bars(20, "Conversation cost after 5 turns, by mode (cumulative, cache-aware)",
         "ONE ongoing 5-question GitHub conversation. With GitHub's large catalog the "
         "per-turn catalog tax dominates, so Search (-23%) and Code (-72%) BOTH beat "
         "Standard — the opposite of the F5 demo. Code wins biggest.",
         0, 33, 12, 8,
         [{"expr": 'agw_ghconv_cum_cost{turn="5"}', "legendFormat": "{{mode}}"}],
         unit="currencyUSD", dec=4),
    bars(21, "Conversation tokens after 5 turns, by mode (cumulative)",
         "Cumulative total tokens across the 5-question conversation. Code keeps the "
         "transcript ~4x smaller (only summaries return), Standard re-sends 28 verbose "
         "schemas each turn.",
         12, 33, 12, 8,
         [{"expr": 'agw_ghconv_cum_total_tokens{turn="5"}', "legendFormat": "{{mode}}"}]),
    bars(22, "Cache-read tokens after 5 turns, by mode (cumulative)",
         "gpt-5.5 prompt caching: tokens served from cache over the conversation (stable "
         "prefix = system + tools + earlier turns). Standard's giant catalog caches heavily.",
         0, 41, 12, 8,
         [{"expr": 'agw_ghconv_cum_cached_tokens{turn="5"}', "legendFormat": "{{mode}}"}]),
    {"id": 23, "type": "text", "title": "Single call vs conversation — and vs the F5 demo",
     "gridPos": {"h": 8, "w": 12, "x": 12, "y": 41},
     "options": {"mode": "markdown", "content":
        "**GitHub's catalog is large (~4,721 tok), and that decides everything:**\n\n"
        "- **Per call** — Search shrinks tool context **~92%** (369 vs 4,721); Code **~37%**. "
        "Code is cheapest on 4 of 5 questions.\n\n"
        "- **Long conversation** — unlike F5 (demo 103, small catalog, where Search cost "
        "~4.8x MORE), here the catalog tax is so big that **Search (-23%) and Code (-72%) "
        "both beat Standard**. Code wins biggest — only summaries return.\n\n"
        "**Catalog size is the deciding variable.** Measure for your own catalog."}},

    {"id": 14, "type": "text", "title": "The 5 GitHub questions asked",
     "gridPos": {"h": 5, "w": 24, "x": 0, "y": 49},
     "options": {"mode": "markdown", "content":
        "Each question is asked through **Standard**, **Search**, and **Code** mode against the external GitHub MCP (read-only):\n"
        "1. My login, name, public repos, and follower count.\n"
        "2. My 10 most recently updated repositories with their primary language.\n"
        "3. The open pull requests I have authored.\n"
        "4. Open issues assigned to me, with titles and repos.\n"
        "5. My most recently updated repository and its 5 most recent commits."}},
]

dash = {
    "title": "GitHub — MCP Tool Modes",
    "uid": "agw-github-tool-modes",
    "schemaVersion": 39,
    "time": {"from": "now-6h", "to": "now"},
    "panels": panels,
}
(HERE / "dashboard-github.json").write_text(json.dumps(dash, indent=2) + "\n")
print(f"wrote dashboard-github.json ({len(panels)} panels)")
