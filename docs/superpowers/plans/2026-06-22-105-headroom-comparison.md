# 105 — Headroom Comparison Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build demo `105-ent-headroom-comp-tokenomics` that measures whether AgentGateway tool modes (Standard/Search/Code) and Headroom content-compression *stack* on the identical 104 GitHub-MCP workload, scoring cost **and** answer quality across a 3×2 matrix on a small and a large repo.

**Architecture:** Fork demo 104 wholesale (kind + Enterprise AGW + OpenAI + GitHub external MCP in 3 tool modes). Add Headroom as a second, independent knob: a local `headroom proxy` the harness can be pointed at via an `LLM_URL` env var, which forwards to AGW `/openai`. Add an LLM-judge quality scorer and a `run_matrix.sh` driver over the 12 cells.

**Tech Stack:** bash, kind, kubectl, helm, Enterprise AgentGateway v2026.6.1, Python 3.10+ (httpx, mcp, prometheus_client), Headroom (`headroom-ai[all]`, `headroom proxy`), OpenAI gpt-5.5.

**Convention note:** This repo has no test runner (CLAUDE.md). Verification is bash `set -euo pipefail`, `bash -n` syntax checks, `python -m py_compile`, and the `test.sh` smoke flow — not unit tests.

---

### Task 0: Verify Headroom proxy upstream targeting (BLOCKING)

**Files:** none (research task — output is a decision recorded in README/REPORT).

- [ ] **Step 1: Confirm the proxy and its upstream knob**

Run:
```bash
pip install --dry-run 'headroom-ai[all]' 2>&1 | head -5 || true
python -m pip download headroom-ai --no-deps -d /tmp/hr-check 2>&1 | tail -3 || true
```
Then read the proxy docs at https://github.com/headroomlabs-ai/headroom (proxy section) and confirm how the upstream LLM base URL is set (env var or flag).

- [ ] **Step 2: Record the integration decision**

Two valid outcomes:
- **A (preferred):** proxy supports custom upstream → set it to `http://localhost:8080/openai` (AGW `/openai`). Harness ON-path: `LLM_URL=http://localhost:8787/v1/...`.
- **B (fallback):** proxy only targets OpenAI directly → ON-path bypasses AGW for the LLM call (`harness → Headroom → OpenAI`); AGW catalog effect unchanged. Note the lost AGW tracing on ON-path in REPORT.md.

Record the chosen path and exact proxy launch command for use in Task 2.

---

### Task 1: Scaffold 105 by copying 104

**Files:**
- Create: `105-ent-headroom-comp-tokenomics/` (copy of `104-ent-github-tokenomics/` minus `.venv`, `REPORT.md` numbers, `COST-ANALYSIS.md` numbers)

- [ ] **Step 1: Copy the demo, excluding the venv and stale reports**

```bash
cd "$(git rev-parse --show-toplevel)"
rsync -a --exclude 'harness/.venv' 104-ent-github-tokenomics/ 105-ent-headroom-comp-tokenomics/
rm -f 105-ent-headroom-comp-tokenomics/REPORT.md 105-ent-headroom-comp-tokenomics/COST-ANALYSIS.md
```

- [ ] **Step 2: Verify scripts still parse**

```bash
for s in 105-ent-headroom-comp-tokenomics/*.sh; do bash -n "$s" && echo "ok $s"; done
```
Expected: `ok` for each script.

- [ ] **Step 3: Commit**

```bash
git add 105-ent-headroom-comp-tokenomics
git commit -m "feat(105): scaffold from 104"
```

---

### Task 2: Add the Headroom knob to deploy + cleanup

**Files:**
- Modify: `105-ent-headroom-comp-tokenomics/deploy.sh`
- Modify: `105-ent-headroom-comp-tokenomics/cleanup.sh`

- [ ] **Step 1: Change the cluster name**

In `deploy.sh` and `cleanup.sh` change the default `CLUSTER_NAME` from `agw-github-tokenomics` to `agw-headroom-comp`.

- [ ] **Step 2: Add a Headroom install + launch step to `deploy.sh`**

Append before the final banner (uses the venv the harness creates; install + launch the proxy in the background, writing its PID to a file so cleanup can stop it). Use the exact launch command decided in Task 0:

```bash
echo ""
echo "==> Step 7: Headroom compression proxy (local)..."
HR_VENV="${SCRIPT_DIR}/harness/.venv"
[[ -d "${HR_VENV}" ]] || python3 -m venv "${HR_VENV}"
"${HR_VENV}/bin/pip" install -q --upgrade pip
"${HR_VENV}/bin/pip" install -q 'headroom-ai[all]'
echo "    Headroom installed. Launch the proxy when running the matrix:"
echo "      HEADROOM_UPSTREAM=http://localhost:8080/openai \\"
echo "        ${HR_VENV}/bin/headroom proxy --port 8787   # (exact flags per Task 0)"
```
(Per repo convention the proxy is launched at run time alongside the port-forwards, not held open by deploy.sh — see `run_matrix.sh`.)

- [ ] **Step 3: Verify**

```bash
bash -n 105-ent-headroom-comp-tokenomics/deploy.sh && bash -n 105-ent-headroom-comp-tokenomics/cleanup.sh && echo ok
```

- [ ] **Step 4: Commit**

```bash
git add 105-ent-headroom-comp-tokenomics/deploy.sh 105-ent-headroom-comp-tokenomics/cleanup.sh
git commit -m "feat(105): own cluster name + Headroom proxy install in deploy"
```

---

### Task 3: Make the harness Headroom-aware (LLM_URL switch) + answer persistence

**Files:**
- Modify: `105-ent-headroom-comp-tokenomics/harness/gh_questions.py`
- Modify: `105-ent-headroom-comp-tokenomics/harness/gh_conversation.py`
- Modify: `105-ent-headroom-comp-tokenomics/harness/gh_chat.py`

- [ ] **Step 1: Replace the hard-coded LLM endpoint in all three files**

Change:
```python
LLM = GW + "/openai"
```
to:
```python
# Headroom knob: when HEADROOM=on, point LLM_URL at the local Headroom proxy
# (which forwards to AGW /openai). Default = straight to AGW /openai (Headroom OFF).
LLM = os.environ.get("LLM_URL", GW + "/openai")
HEADROOM = os.environ.get("HEADROOM", "off").lower() in ("1", "on", "true", "yes")
```

- [ ] **Step 2: Tag metrics with the Headroom state in `gh_questions.py`**

Add `"headroom"` to the `labels` list and include `"headroom": ("on" if HEADROOM else "off")` in every `lbl` dict, and change the job name to `agw_hr_questions`. Add an env-driven metric prefix so 105 metrics don't collide with 104:
```python
JOB = os.environ.get("PUSH_JOB", "agw_hr_questions")
```
Use `JOB` in `delete_from_gateway` / `push_to_gateway`.

- [ ] **Step 3: Persist each answer to a results file in `gh_questions.py`**

In `run()`, also capture the final answer text (`msg.get("content")` on the no-tool-calls branch) and return it as `"answer"`. In `main()`, append one JSON line per (question, mode) to `RESULTS_FILE`:
```python
RESULTS_FILE = os.environ.get("RESULTS_FILE", "results.jsonl")
...
import time  # top of file
with open(RESULTS_FILE, "a") as f:
    f.write(json.dumps({
        "repo": REPO, "headroom": ("on" if HEADROOM else "off"),
        "question": qid, "mode": mode, "cost": m["cost"],
        "total": m["total"], "first": m["first"], "calls": m["calls"],
        "ok": m["ok"], "answer": m.get("answer", ""),
    }) + "\n")
```

- [ ] **Step 4: Verify all three compile**

```bash
cd 105-ent-headroom-comp-tokenomics/harness
python3 -m py_compile gh_questions.py gh_conversation.py gh_chat.py && echo ok
```

- [ ] **Step 5: Commit**

```bash
git add 105-ent-headroom-comp-tokenomics/harness/gh_*.py
git commit -m "feat(105): harness LLM_URL/HEADROOM switch, hr metrics, answer persistence"
```

---

### Task 4: LLM-judge quality scorer

**Files:**
- Create: `105-ent-headroom-comp-tokenomics/harness/judge.py`

- [ ] **Step 1: Write the judge module**

It reads `results.jsonl`, takes the `standard` + `headroom=off` answer per (repo, question) as the baseline, asks the judge model (via the OFF-path `/openai`) to score every other answer 0–5 for correctness/completeness vs that baseline, and pushes `agw_hr_quality_score{repo,mode,headroom,question}` to the pushgateway plus prints a table.

```python
"""Score every recorded answer (results.jsonl) for quality vs the Standard/
Headroom-OFF baseline answer, using an LLM judge via the OFF-path /openai route.
Pushes agw_hr_quality_score to the pushgateway and prints a table."""
import json, os, collections, httpx
from prometheus_client import CollectorRegistry, Gauge, delete_from_gateway, push_to_gateway

GW = os.environ.get("GATEWAY_URL", "http://localhost:8080")
JUDGE_LLM = os.environ.get("JUDGE_LLM_URL", GW + "/openai")  # always OFF-path (uncompressed)
PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "http://localhost:9091")
RESULTS_FILE = os.environ.get("RESULTS_FILE", "results.jsonl")
NO_TEMP = os.environ.get("LLM_NO_TEMPERATURE", "").lower() in ("1", "true", "yes")

JUDGE_SYS = ("You are a strict grader. Given a QUESTION, a reference BASELINE answer, "
             "and a CANDIDATE answer, score how well the candidate matches the baseline's "
             "factual content and completeness from 0 (wrong/empty) to 5 (fully equivalent). "
             "Reply with ONLY a JSON object: {\"score\": <int 0-5>, \"why\": \"<one line>\"}.")

def rows():
    with open(RESULTS_FILE) as f:
        return [json.loads(l) for l in f if l.strip()]

def score(client, question, baseline, candidate):
    body = {"model": "", "messages": [
        {"role": "system", "content": JUDGE_SYS},
        {"role": "user", "content": f"QUESTION:\n{question}\n\nBASELINE:\n{baseline}\n\nCANDIDATE:\n{candidate}"},
    ]}
    if not NO_TEMP:
        body["temperature"] = 0
    resp = client.post(JUDGE_LLM, json=body, timeout=120).json()
    txt = resp["choices"][0]["message"].get("content", "{}")
    try:
        obj = json.loads(txt[txt.find("{"): txt.rfind("}") + 1])
        return int(obj.get("score", 0)), str(obj.get("why", ""))
    except Exception:
        return 0, f"unparseable: {txt[:80]}"

def main():
    data = rows()
    baseline = {}  # (repo, question) -> answer
    for r in data:
        if r["mode"] == "standard" and r["headroom"] == "off":
            baseline[(r["repo"], r["question"])] = r["answer"]
    reg = CollectorRegistry()
    g = Gauge("agw_hr_quality_score", "0-5 answer quality vs baseline",
              ["repo", "mode", "headroom", "question"], registry=reg)
    print(f"{'repo':<28}{'mode':<10}{'hr':<5}{'question':<10}{'score':>6}  why")
    with httpx.Client() as client:
        for r in data:
            base = baseline.get((r["repo"], r["question"]))
            if base is None:
                continue
            s, why = score(client, r["question"], base, r["answer"])
            g.labels(repo=r["repo"], mode=r["mode"], headroom=r["headroom"],
                     question=r["question"]).set(s)
            print(f"{r['repo']:<28}{r['mode']:<10}{r['headroom']:<5}{r['question']:<10}{s:>6}  {why[:60]}")
    try:
        delete_from_gateway(PUSHGATEWAY, job="agw_hr_quality")
    except Exception:
        pass
    try:
        push_to_gateway(PUSHGATEWAY, job="agw_hr_quality", registry=reg)
        print(f"\nPushed quality scores to {PUSHGATEWAY}")
    except Exception as e:
        print(f"\nWARN: could not push ({e})")

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Verify it compiles**

```bash
python3 -m py_compile 105-ent-headroom-comp-tokenomics/harness/judge.py && echo ok
```

- [ ] **Step 3: Commit**

```bash
git add 105-ent-headroom-comp-tokenomics/harness/judge.py
git commit -m "feat(105): LLM-judge answer-quality scorer"
```

---

### Task 5: `run_matrix.sh` — drive all 12 cells + judge

**Files:**
- Create: `105-ent-headroom-comp-tokenomics/run_matrix.sh`

- [ ] **Step 1: Write the driver**

Loops repos (small,large) × headroom (off,on). For each combo it sets `GH_REPO`, `HEADROOM`, and (on) `LLM_URL`, runs `gh_questions.py` (which itself loops the 3 modes and appends to `results.jsonl`). Baseline (standard/off) is captured because off-runs include standard. After all runs, calls `judge.py`. It manages the proxy/pushgateway port-forwards and the Headroom proxy launch.

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="agentgateway-system"
PY="${SCRIPT_DIR}/harness/.venv/bin/python"
HR="${SCRIPT_DIR}/harness/.venv/bin/headroom"
REPO_SMALL="${REPO_SMALL:-sebbycorp/agw-tokenomics-sandbox}"
REPO_LARGE="${REPO_LARGE:?set REPO_LARGE=owner/name to the large read-only repo}"
export LLM_NO_TEMPERATURE="${LLM_NO_TEMPERATURE:-1}"
export RESULTS_FILE="${SCRIPT_DIR}/harness/results.jsonl"
: > "${RESULTS_FILE}"   # fresh

echo "==> Port-forwards (proxy 8080, pushgateway 9091)..."
kubectl port-forward deployment/agentgateway-proxy -n "$NS" 8080:80 >/tmp/pf-hr-proxy.log 2>&1 &
PF1=$!
kubectl port-forward svc/prometheus-prometheus-pushgateway -n observability 9091:9091 >/tmp/pf-hr-pg.log 2>&1 &
PF2=$!
echo "==> Headroom proxy on :8787 (upstream AGW /openai)..."
HEADROOM_UPSTREAM=http://localhost:8080/openai "$HR" proxy --port 8787 >/tmp/hr-proxy.log 2>&1 &
PF3=$!
trap 'kill $PF1 $PF2 $PF3 2>/dev/null || true' EXIT
sleep 6

run_one() {  # $1=repo $2=headroom(off|on)
  local repo="$1" hr="$2"
  echo ""; echo "########## repo=$repo headroom=$hr ##########"
  export GH_REPO="$repo" HEADROOM="$hr"
  if [[ "$hr" == "on" ]]; then export LLM_URL="http://localhost:8787/openai"; else unset LLM_URL; fi
  "$PY" "${SCRIPT_DIR}/harness/gh_questions.py"
}

for repo in "$REPO_SMALL" "$REPO_LARGE"; do
  for hr in off on; do run_one "$repo" "$hr"; done
done

echo ""; echo "==> Scoring answer quality (LLM judge)..."
RESULTS_FILE="${RESULTS_FILE}" "$PY" "${SCRIPT_DIR}/harness/judge.py"
echo ""; echo "==> Done. Raw results: ${RESULTS_FILE}"
```

- [ ] **Step 2: Make executable + verify**

```bash
chmod +x 105-ent-headroom-comp-tokenomics/run_matrix.sh
bash -n 105-ent-headroom-comp-tokenomics/run_matrix.sh && echo ok
```

- [ ] **Step 3: Commit**

```bash
git add 105-ent-headroom-comp-tokenomics/run_matrix.sh
git commit -m "feat(105): run_matrix.sh drives 12 cells + judge"
```

---

### Task 6: test.sh smoke (OFF vs ON one question)

**Files:**
- Modify: `105-ent-headroom-comp-tokenomics/test.sh`

- [ ] **Step 1: Rework test.sh to show one question OFF then ON**

Keep the port-forward + venv bootstrap. Replace the per-mode loop with: launch the Headroom proxy, then run `gh_chat.py search "$QUESTION"` once with `HEADROOM=off` and once with `HEADROOM=on LLM_URL=http://localhost:8787/openai`, printing a header before each so the token lines are comparable.

- [ ] **Step 2: Verify**

```bash
bash -n 105-ent-headroom-comp-tokenomics/test.sh && echo ok
```

- [ ] **Step 3: Commit**

```bash
git add 105-ent-headroom-comp-tokenomics/test.sh
git commit -m "feat(105): test.sh smoke compares Headroom OFF vs ON"
```

---

### Task 7: Docs — README, .env.example, COST-ANALYSIS skeleton, REPORT skeleton

**Files:**
- Modify: `105-ent-headroom-comp-tokenomics/README.md`
- Modify: `105-ent-headroom-comp-tokenomics/.env.example`
- Create: `105-ent-headroom-comp-tokenomics/COST-ANALYSIS.md`
- Create: `105-ent-headroom-comp-tokenomics/REPORT.md`

- [ ] **Step 1: Rewrite README.md** around the "do they stack?" thesis: the two-knob architecture diagram (mermaid), the 12-cell matrix table, quick start (`deploy.sh` → `test.sh` → `REPO_LARGE=… ./run_matrix.sh`), the safety section copied from 104, and a "Results — filled in after a run" pointer to REPORT.md. Add the Task-0 integration decision (A or B) note.

- [ ] **Step 2: Update .env.example** — add `REPO_LARGE=` (the large read-only repo) and any Headroom env (e.g. `HEADROOM_OUTPUT_SHAPER=1`) discovered in Task 0; keep `AGENTGATEWAY_LICENSE_KEY`, `OPENAI_API_KEY`, `GITHUB_PAT`.

- [ ] **Step 3: Write COST-ANALYSIS.md** as a skeleton with the empty 12-cell table (rows = repo×mode, cols = OFF $, ON $, Δ%, OFF quality, ON quality) and the method note; numbers filled after a real run.

- [ ] **Step 4: Write REPORT.md** as a skeleton stating the thesis, method, and the expected-findings hypotheses from the spec §7, with a clear "MEASURED RESULTS PENDING A LIVE RUN" banner so it is never mistaken for real data.

- [ ] **Step 5: Commit**

```bash
git add 105-ent-headroom-comp-tokenomics/README.md 105-ent-headroom-comp-tokenomics/.env.example \
        105-ent-headroom-comp-tokenomics/COST-ANALYSIS.md 105-ent-headroom-comp-tokenomics/REPORT.md
git commit -m "docs(105): README + env + cost/report skeletons (results pending live run)"
```

---

### Task 8: Observability panels

**Files:**
- Modify: `105-ent-headroom-comp-tokenomics/observability/dashboard-github.json` (rename concept → headroom) or add a new panel set.

- [ ] **Step 1:** Add two panels keyed on the new metrics: a bar/timeseries of `agw_hr_questions`-derived cost grouped by `headroom` (OFF vs ON) per mode, and a table of `agw_hr_quality_score`. Keep 104's existing panels if reused; ensure metric names match Task 3/4 (`agw_hr_*`).

- [ ] **Step 2: Verify JSON parses**

```bash
python3 -c "import json,sys; json.load(open('105-ent-headroom-comp-tokenomics/observability/dashboard-github.json')); print('ok')"
```

- [ ] **Step 3: Commit**

```bash
git add 105-ent-headroom-comp-tokenomics/observability
git commit -m "feat(105): Grafana panels for Headroom OFF/ON cost + quality"
```

---

### Task 9: Update CLAUDE.md + memory

**Files:**
- Modify: `CLAUDE.md` (the demo table + Enterprise note)

- [ ] **Step 1:** Add a row to the cluster/version table: `105-ent-headroom-comp-tokenomics | agw-headroom-comp | v2026.6.1`, and extend the "103 and 104 use Enterprise" note to include 105 (also fronts external GitHub MCP, adds the Headroom proxy knob).

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: register demo 105 in CLAUDE.md demo table"
```

---

## Self-Review

**Spec coverage:**
- §2 two-knob architecture → Tasks 2,3,5 ✓
- §3 12-cell matrix on 2 repos → Task 5 (`run_matrix.sh`) ✓
- §4 LLM-judge quality → Task 4 ✓
- §5 deliverables (deploy/harness/run_matrix/observability/docs) → Tasks 2,3,5,8,7 ✓
- §6 safety unchanged → inherited via Task 1 copy; restated in README Task 7 ✓
- §7 expected findings → REPORT skeleton Task 7 ✓
- Task 0 covers the spec's §2 implementation-time verification ✓

**Placeholder scan:** Large-repo identity is a runtime input (`REPO_LARGE` env), not a code placeholder — intentional per spec §3. Report numbers are explicitly pending a live run (the demo cannot fabricate measured costs). No code-level TODOs.

**Type/name consistency:** metric namespace `agw_hr_*` and jobs `agw_hr_questions`/`agw_hr_quality` consistent across Tasks 3,4,8; env vars `HEADROOM`, `LLM_URL`, `GH_REPO`, `RESULTS_FILE`, `REPO_LARGE`, `REPO_SMALL` consistent across Tasks 3,4,5.

**Honesty gate:** REPORT.md and COST-ANALYSIS.md ship as skeletons with a "results pending live run" banner — the agent must not invent measured numbers; real numbers require the user to run `run_matrix.sh` with their license/keys (and it spends OpenAI tokens).
