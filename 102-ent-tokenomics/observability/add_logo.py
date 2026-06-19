"""Inject an agentgateway logo header panel into each dashboard JSON.

Adds a text panel (HTML <img> with the logo as a base64 SVG data URI) at the top
of the dashboard and shifts all existing panels down by the logo height. Idempotent:
if a logo panel (id 9000) already exists, it is replaced rather than duplicated.
"""
import base64
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).parent
LOGO_ID = 9000
LOGO_H = 3  # grid rows

svg = (HERE / "logo.svg").read_bytes()
b64 = base64.b64encode(svg).decode()
data_uri = f"data:image/svg+xml;base64,{b64}"

logo_panel = {
    "id": LOGO_ID,
    "type": "text",
    "title": "",
    "transparent": True,
    "gridPos": {"h": LOGO_H, "w": 24, "x": 0, "y": 0},
    "options": {
        "mode": "html",
        "content": (
            f'<div style="display:flex;align-items:center;height:100%">'
            f'<img src="{data_uri}" style="height:46px"/></div>'
        ),
    },
}


def inject(path: pathlib.Path) -> None:
    dash = json.loads(path.read_text())
    panels = [p for p in dash.get("panels", []) if p.get("id") != LOGO_ID]
    # shift existing panels down to make room for the logo header
    for p in panels:
        if "gridPos" in p:
            p["gridPos"]["y"] = p["gridPos"].get("y", 0) + LOGO_H
    dash["panels"] = [logo_panel] + panels
    path.write_text(json.dumps(dash, indent=2) + "\n")
    print(f"  logo injected into {path.name} ({len(panels)} panels shifted)")


if __name__ == "__main__":
    targets = sys.argv[1:] or ["dashboard.json", "dashboard-eval.json"]
    for t in targets:
        inject(HERE / t)
