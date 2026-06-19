"""Generate dashboard-f5.json (F5 tool-modes Grafana dashboard) with the embedded
agentgateway logo. Run:  python3 build_dashboard.py
Metrics come from harness/f5_questions.py (job=agw_f5_questions)."""
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
                            f'F5 BIG-IP via MCP tool modes</span></div>'}},

    stat(1, "Avg first-call tool tokens — STANDARD", "All 29 F5 tools sent to the model every call.",
         0, 3, 8, 'avg(agw_f5q_first_call_tokens{mode="standard"})', color="red"),
    stat(2, "Avg first-call tool tokens — SEARCH", "Only get_tool + invoke_tool sent; the model discovers tools on demand.",
         8, 3, 8, 'avg(agw_f5q_first_call_tokens{mode="search"})', color="green"),
    stat(3, "Tool-context reduction (Search vs Standard)", "How much smaller the per-call F5 tool context is with Search mode.",
         16, 3, 8, '(1 - avg(agw_f5q_first_call_tokens{mode="search"}) / avg(agw_f5q_first_call_tokens{mode="standard"})) * 100',
         unit="percent"),

    stat(4, "Tools advertised — Standard (full F5 catalog)", "F5 tools the model sees in Standard mode (Search=2, Code=1 — see the by-mode bar panel).",
         0, 9, 8, 'avg(agw_f5q_advertised_tools{mode="standard"})', color="red"),
    stat(5, "Questions answered successfully", "Share of the 5 F5 questions completed across all modes.",
         8, 9, 8, 'avg(agw_f5q_task_ok) * 100', unit="percent"),
    stat(6, "Avg cost per task — Search", "Average USD per F5 question in Search mode (gpt-5.5 list-price estimate).",
         16, 9, 8, 'avg(agw_f5q_usd_cost{mode="search"})', unit="currencyUSD", color="green", dec=4),

    bars(10, "First-call tool tokens by question — Standard vs Search", "Per F5 question: tool-definition tokens the model carries. Standard (29 tools) vs Search (2). Shorter is better.",
         0, 15, 12, 9,
         [{"expr": 'agw_f5q_first_call_tokens{mode="standard"}', "legendFormat": "{{question}} — standard"},
          {"expr": 'agw_f5q_first_call_tokens{mode="search"}', "legendFormat": "{{question}} — search"}]),
    bars(11, "Tools advertised to the model, by mode", "Standard exposes the full F5 catalog; Search and Code keep it tiny.",
         12, 15, 12, 9,
         [{"expr": 'avg by (mode) (agw_f5q_advertised_tools)', "legendFormat": "{{mode}}"}]),

    bars(12, "Total tokens per question, by mode (the full picture)", "Total prompt+completion tokens incl. the extra Search/Code round-trips. Search isn't always lowest total on tiny tasks, but its per-call context is.",
         0, 24, 12, 9,
         [{"expr": 'agw_f5q_total_tokens{mode="standard"}', "legendFormat": "{{question}} — standard"},
          {"expr": 'agw_f5q_total_tokens{mode="search"}', "legendFormat": "{{question}} — search"},
          {"expr": 'agw_f5q_total_tokens{mode="code"}', "legendFormat": "{{question}} — code"}]),
    bars(13, "Cost per task by question & mode", "USD per F5 question by mode (gpt-5.5 list-price estimate).",
         12, 24, 12, 9,
         [{"expr": 'agw_f5q_usd_cost{mode="standard"}', "legendFormat": "{{question}} — standard"},
          {"expr": 'agw_f5q_usd_cost{mode="search"}', "legendFormat": "{{question}} — search"},
          {"expr": 'agw_f5q_usd_cost{mode="code"}', "legendFormat": "{{question}} — code"}],
         unit="currencyUSD", dec=5),

    {"id": 14, "type": "text", "title": "The 5 F5 questions asked",
     "gridPos": {"h": 5, "w": 24, "x": 0, "y": 33},
     "options": {"mode": "markdown", "content":
        "Each question is asked through **Standard**, **Search**, and **Code** mode against the real F5 BIG-IP:\n"
        "1. How many LTM pools are in Common, and list their names?\n"
        "2. List the LTM virtual servers and their destinations.\n"
        "3. What is the BIG-IP version, hostname, and platform?\n"
        "4. What is the HA failover status?\n"
        "5. List the SSL certificates and their expiration dates."}},
]

dash = {
    "title": "F5 BIG-IP — MCP Tool Modes",
    "uid": "agw-f5-tool-modes",
    "schemaVersion": 39,
    "time": {"from": "now-6h", "to": "now"},
    "panels": panels,
}
(HERE / "dashboard-f5.json").write_text(json.dumps(dash, indent=2) + "\n")
print(f"wrote dashboard-f5.json ({len(panels)} panels)")
