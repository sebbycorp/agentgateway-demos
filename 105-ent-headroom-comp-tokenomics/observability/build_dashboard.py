"""Generate dashboard-github.json (105 Headroom-comparison Grafana dashboard) with
the embedded agentgateway logo. Run:  python3 build_dashboard.py

Metrics come from:
  harness/gh_questions.py    -> agw_hr_*       labels: question, mode, headroom, repo
  harness/gh_conversation.py -> agw_hrconv_*   labels: mode, turn, headroom, repo
  harness/judge.py           -> agw_hr_quality_score  labels: repo, mode, headroom, question

The dashboard is framed around the OFF vs ON comparison: most panels split by the
`headroom` label so AGW-only (OFF) and AGW+Headroom (ON) sit side by side."""
import base64
import json
import pathlib

HERE = pathlib.Path(__file__).parent
b64 = base64.b64encode((HERE / "logo.svg").read_bytes()).decode()
logo_uri = f"data:image/svg+xml;base64,{b64}"


def stat(id, title, desc, x, y, w, expr, color=None, unit=None, dec=0):
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
                            f'AGW tool modes + Headroom — do the savings stack?</span></div>'}},

    # ----- Headline: avg cost per task, OFF vs ON, per AGW mode -----
    stat(1, "Avg cost/task — Search, Headroom OFF", "AGW Search alone (no compression). Lower is better.",
         0, 3, 8, 'avg(agw_hr_usd_cost{mode="search",headroom="off"})', unit="currencyUSD", color="orange", dec=4),
    stat(2, "Avg cost/task — Search, Headroom ON", "AGW Search + Headroom payload compression (the stacked cell).",
         8, 3, 8, 'avg(agw_hr_usd_cost{mode="search",headroom="on"})', unit="currencyUSD", color="green", dec=4),
    stat(3, "Stacked saving (Search: ON vs OFF)", "How much Headroom adds on top of AGW Search. Positive = Headroom helps.",
         16, 3, 8,
         '(1 - avg(agw_hr_usd_cost{mode="search",headroom="on"}) / avg(agw_hr_usd_cost{mode="search",headroom="off"})) * 100',
         unit="percent"),

    # ----- Cost per task by mode, split by Headroom state -----
    bars(10, "Avg cost/task by AGW mode — Headroom OFF vs ON", "Each AGW mode with compression off then on. The gap between the two bars is what Headroom adds.",
         0, 9, 12, 9,
         [{"expr": 'avg by (mode, headroom) (agw_hr_usd_cost)', "legendFormat": "{{mode}} — hr={{headroom}}"}],
         unit="currencyUSD", dec=5),
    bars(11, "Avg total tokens/task by AGW mode — OFF vs ON", "Total prompt+completion tokens per task. Headroom should shrink the payload-heavy cells most.",
         12, 9, 12, 9,
         [{"expr": 'avg by (mode, headroom) (agw_hr_total_tokens)', "legendFormat": "{{mode}} — hr={{headroom}}"}]),

    # ----- Per-repo cost: does the large repo give Headroom more to compress? -----
    bars(12, "Avg cost/task by repo & Headroom state", "Small (sandbox) vs large repo. Hypothesis: Headroom helps more on the large repo (heavier JSON payloads).",
         0, 18, 12, 9,
         [{"expr": 'avg by (repo, headroom) (agw_hr_usd_cost)', "legendFormat": "{{repo}} — hr={{headroom}}"}],
         unit="currencyUSD", dec=5),
    bars(13, "First-call tool tokens by AGW mode (Headroom-independent)", "AGW-side catalog tax: Standard (28 tools) vs Search (2) vs Code (1). Headroom doesn't touch this layer.",
         12, 18, 12, 9,
         [{"expr": 'avg by (mode) (agw_hr_first_call_tokens)', "legendFormat": "{{mode}}"}]),

    # ----- Quality: did compression hurt answers? -----
    bars(14, "Answer quality (0-5) by mode & Headroom — vs Standard/OFF baseline", "LLM-judge score. ON bars near 5 = compression preserved the answer. A low ON bar with a low cost = cheaper-but-WORSE; do not celebrate it.",
         0, 27, 24, 9,
         [{"expr": 'avg by (mode, headroom) (agw_hr_quality_score)', "legendFormat": "{{mode}} — hr={{headroom}}"}],
         unit="short", dec=2),

    # ----- Conversation cumulative cost, OFF vs ON -----
    bars(20, "Conversation cost after 5 turns — by mode & Headroom (cumulative)",
         "One ongoing 5-question conversation. Over turns the payload accumulates, so Headroom's compression should matter more here than in single calls.",
         0, 36, 12, 8,
         [{"expr": 'agw_hrconv_cum_cost{turn="5"}', "legendFormat": "{{mode}} — hr={{headroom}} — {{repo}}"}],
         unit="currencyUSD", dec=4),
    bars(21, "Conversation tokens after 5 turns — by mode & Headroom (cumulative)",
         "Cumulative total tokens across the conversation, OFF vs ON.",
         12, 36, 12, 8,
         [{"expr": 'agw_hrconv_cum_total_tokens{turn="5"}', "legendFormat": "{{mode}} — hr={{headroom}} — {{repo}}"}]),

    {"id": 30, "type": "text", "title": "How to read this dashboard",
     "gridPos": {"h": 7, "w": 24, "x": 0, "y": 44},
     "options": {"mode": "markdown", "content":
        "**Two knobs, different layers.** AGW tool modes shrink the **tool catalog** "
        "(panel 13 — Headroom can't change it). Headroom shrinks the **payload** (the gap "
        "between `hr=off` and `hr=on` bars in panels 10–12, 20–21).\n\n"
        "**Do they stack?** Compare `hr=on` vs `hr=off` *within the same AGW mode*. A real "
        "stacked win shows the ON bar clearly below the OFF bar — especially for Search on "
        "the large repo.\n\n"
        "**Fairness gate (panel 14).** A cheaper ON cell only counts if its quality bar stays "
        "near the baseline (5). Cheaper-but-lower-quality is a regression, not a saving.\n\n"
        "_Run `./run_matrix.sh` to populate; numbers are list-price gpt-5.5 estimates._"}},
]

dash = {
    "title": "AGW Tool Modes + Headroom",
    "uid": "agw-headroom-comparison",
    "schemaVersion": 39,
    "time": {"from": "now-6h", "to": "now"},
    "panels": panels,
}
(HERE / "dashboard-github.json").write_text(json.dumps(dash, indent=2) + "\n")
print(f"wrote dashboard-github.json ({len(panels)} panels)")
