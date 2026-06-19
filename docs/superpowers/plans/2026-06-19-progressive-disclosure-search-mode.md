# Enterprise Progressive Disclosure (MCP Search Mode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained AgentGateway Enterprise demo (`102-ent-progressive-discloure/`) that deploys MCP search mode and produces hard A/B data proving search mode cuts prompt tokens and cost versus default mode, visualized in a simple Grafana dashboard.

**Architecture:** A kind cluster runs Solo Enterprise AgentGateway. A synthetic Python MCP server is deployed at three tool counts (10/50/100). Two `EnterpriseAgentgatewayBackend`s expose each server in `default` and `Search` tool modes via HTTPRoutes. A Python harness runs an identical agent task through an OpenAI model (routed through the gateway) against each (mode × tool_count) route, capturing real `prompt_tokens` and cost into `results.csv`/`results.json` and pushing labeled gauges to a Prometheus Pushgateway. Grafana reads Prometheus and charts the savings.

**Tech Stack:** kind, kubectl, helm; Solo Enterprise AgentGateway v2026.6.1; Gateway API v1.5.0; Python 3.12 (`mcp`, `httpx`, `prometheus_client`); Prometheus + Pushgateway + Grafana (Helm); OpenAI `gpt-4o-mini`.

## Global Constraints

- Cluster name: `agw-progressive-disclosure`
- Namespace: `agentgateway-system`
- Solo Enterprise AgentGateway version: `v2026.6.1`
- Gateway API CRDs version: `v1.5.0`
- Solo UI (`management`) chart version: `0.3.19`
- LLM model: `gpt-4o-mini` (OpenAI), routed through the gateway at `/openai`
- MCP search-mode backend CRD: `enterpriseagentgateway.solo.io/v1alpha1`, kind `EnterpriseAgentgatewayBackend`, field `spec.entMcp.toolMode` ∈ {default, `Search`}
- OpenAI LLM backend CRD: `agentgateway.dev/v1alpha1`, kind `AgentgatewayBackend`
- Tool-count sweep values: `10`, `50`, `100` (deployed as 3 separate server instances)
- Required env vars: `AGENTGATEWAY_LICENSE_KEY`, `OPENAI_API_KEY`
- Secrets via env only; never commit keys. Commit `.env.example`.
- Helm charts from `oci://us-docker.pkg.dev/solo-public/...` (enterprise) and `prometheus-community` / `grafana` repos (observability).
- All work lives under `102-ent-progressive-discloure/`. Run commands from that directory unless noted.

---

## File Structure

```
102-ent-progressive-discloure/
  deploy.sh              # full environment bring-up (idempotent)
  test.sh                # port-forward + run harness sweep + print summary
  cleanup.sh             # delete kind cluster
  step-by-step.sh        # annotated deploy for live demos
  README.md              # architecture, concepts, quick start
  .env.example           # AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY
  mcp-server/
    server.py            # FastMCP synthetic server, TOOL_COUNT env knob
    requirements.txt     # mcp
    Dockerfile           # build image, loaded into kind
  harness/
    run_ab.py            # A/B experiment runner
    pricing.json         # per-1k-token USD prices for gpt-4o-mini
    requirements.txt     # httpx, mcp, prometheus_client
  k8s/
    openai.yaml          # secret + AgentgatewayBackend + HTTPRoute (/openai)
  observability/
    prometheus-values.yaml   # Helm values (enables pushgateway, scrape)
    grafana-values.yaml      # Helm values (datasource + dashboard provisioning)
    dashboard.json           # the Grafana dashboard
```

`deploy.sh` generates the synthetic-server Deployments/Services and the 6 `EnterpriseAgentgatewayBackend`+HTTPRoute pairs in-line via a bash loop (DRY), so there is no separate static backends YAML.

---

## Task 1: Synthetic MCP server

**Files:**
- Create: `102-ent-progressive-discloure/mcp-server/server.py`
- Create: `102-ent-progressive-discloure/mcp-server/requirements.txt`
- Create: `102-ent-progressive-discloure/mcp-server/Dockerfile`

**Interfaces:**
- Produces: an SSE MCP server on `0.0.0.0:8000` (SSE endpoint `/sse`) exposing `TOOL_COUNT` echo tools named `tool_000`…`tool_NNN`. Each tool has input schema fields `text: str`, `number: int = 0`, `flag: bool = False`, `tags: list[str] = []`, `note: str = ""` and returns a deterministic echo string. `TOOL_COUNT` read from env (default `10`).

- [ ] **Step 1: Write `requirements.txt`**

```
mcp>=1.2.0
```

- [ ] **Step 2: Write `server.py`**

```python
"""Synthetic MCP server exposing a configurable number of echo tools.

TOOL_COUNT (env, default 10) controls how many tools are registered. Each tool
carries a realistic multi-field input schema so its serialized definition has a
representative token cost. Tools are pure echo -> runs are deterministic.
"""
import os
from mcp.server.fastmcp import FastMCP

TOOL_COUNT = int(os.environ.get("TOOL_COUNT", "10"))

mcp = FastMCP("synthetic-tools", host="0.0.0.0", port=8000)


def _make_tool(index: int):
    def echo_tool(
        text: str,
        number: int = 0,
        flag: bool = False,
        tags: list[str] | None = None,
        note: str = "",
    ) -> str:
        """Echo back the provided arguments for synthetic tool."""
        return (
            f"tool_{index:03d} echoed: text={text} number={number} "
            f"flag={flag} tags={tags or []} note={note}"
        )

    return echo_tool


for i in range(TOOL_COUNT):
    mcp.add_tool(
        _make_tool(i),
        name=f"tool_{i:03d}",
        description=(
            f"Synthetic echo tool number {i}. Accepts a text string, an integer "
            f"number, a boolean flag, a list of string tags, and a note string, "
            f"then returns them echoed back. Used to demonstrate MCP progressive "
            f"disclosure (search mode) tool {i:03d}."
        ),
    )


if __name__ == "__main__":
    print(f"Starting synthetic MCP server with {TOOL_COUNT} tools (SSE on :8000/sse)")
    mcp.run(transport="sse")
```

- [ ] **Step 3: Write `Dockerfile`**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
EXPOSE 8000
CMD ["python", "server.py"]
```

- [ ] **Step 4: Build the image locally and smoke-test tool count**

Run:
```bash
cd 102-ent-progressive-discloure/mcp-server
docker build -t synthetic-mcp:dev .
docker run -d --rm -e TOOL_COUNT=10 -p 8000:8000 --name smcp synthetic-mcp:dev
sleep 3
curl -sN http://localhost:8000/sse | head -c 200; echo
docker logs smcp | tail -5
docker stop smcp
```
Expected: container logs print `Starting synthetic MCP server with 10 tools`; the `/sse` curl returns an SSE stream preamble (an `event:`/`data:` line) rather than a connection error.

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add 102-ent-progressive-discloure/mcp-server
git commit -m "feat(102): synthetic MCP server with TOOL_COUNT echo tools"
```

---

## Task 2: Enterprise cluster bring-up in `deploy.sh` (Part A)

**Files:**
- Create: `102-ent-progressive-discloure/deploy.sh`
- Create: `102-ent-progressive-discloure/.env.example`

**Interfaces:**
- Produces: a kind cluster `agw-progressive-disclosure` with Enterprise AGW v2026.6.1 control plane, Solo UI, and a `agentgateway-proxy` Gateway in `agentgateway-system`. This is the foundation later deploy parts append to.

- [ ] **Step 1: Write `.env.example`**

```
# Solo Enterprise license key (required) — https://www.solo.io/company/contact
AGENTGATEWAY_LICENSE_KEY=
# OpenAI API key (required for the LLM route used by the A/B harness)
OPENAI_API_KEY=
```

- [ ] **Step 2: Write `deploy.sh` Part A (preflight + cluster + control plane + Gateway)**

This mirrors `101-k8s-ent-code-mode/deploy.sh` exactly, changing only the cluster name. Write the file with this content:

```bash
#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# deploy.sh — Demo 102: Enterprise Progressive Disclosure (MCP Search Mode)
#
# 1. kind cluster + Enterprise AgentGateway control plane + Solo UI + Gateway
# 2. Synthetic MCP servers (TOOL_COUNT 10/50/100) + image load
# 3. EnterpriseAgentgatewayBackends (default + Search) x 3 counts + HTTPRoutes
# 4. OpenAI LLM backend + route
# 5. Observability: Prometheus + Pushgateway + Grafana (provisioned dashboard)
#
# Prereqs: kind, kubectl, helm, docker; AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY
##############################################################################

CLUSTER_NAME="agw-progressive-disclosure"
NAMESPACE="agentgateway-system"
AGW_VERSION="v2026.6.1"
GATEWAY_API_VERSION="v1.5.0"
UI_VERSION="0.3.19"
MGMT_CLUSTER_NAME="mgmt-cluster"
TOOL_COUNTS=(10 50 100)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Checking prerequisites..."
for cmd in kind kubectl helm docker; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' is required." >&2; exit 1; }
done
[[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || { echo "ERROR: AGENTGATEWAY_LICENSE_KEY not set." >&2; exit 1; }
[[ -n "${OPENAI_API_KEY:-}" ]] || { echo "ERROR: OPENAI_API_KEY not set." >&2; exit 1; }
echo "    All prerequisites met."

echo ""
echo "==> Step 1: Creating kind cluster '${CLUSTER_NAME}'..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "    Cluster exists, skipping creation."
else
  kind create cluster --name "${CLUSTER_NAME}"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"
kubectl wait --for=condition=Ready node --all --timeout=120s

echo ""
echo "==> Step 2: Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo ""
echo "==> Step 3: Installing Enterprise AgentGateway CRDs (${AGW_VERSION})..."
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" --version "${AGW_VERSION}"

echo ""
echo "==> Step 4: Installing Enterprise AgentGateway control plane (${AGW_VERSION})..."
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "${NAMESPACE}" --version "${AGW_VERSION}" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"
kubectl rollout status deployment/enterprise-agentgateway -n "${NAMESPACE}" --timeout=180s

echo ""
echo "==> Step 4b: Installing Solo UI (management ${UI_VERSION})..."
helm upgrade -i management \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
  --namespace "${NAMESPACE}" --create-namespace --version "${UI_VERSION}" \
  --set cluster="${MGMT_CLUSTER_NAME}" \
  --set products.agentgateway.enabled=true \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"
kubectl rollout status deployment/solo-enterprise-ui -n "${NAMESPACE}" --timeout=240s || \
  echo "    (UI still starting)"

echo ""
echo "==> Step 5: Creating agentgateway-proxy Gateway..."
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n "${NAMESPACE}" --timeout=300s

# --- Parts B/C/D/E appended in later tasks ---
```

- [ ] **Step 3: Make executable and run Part A**

Run:
```bash
cd 102-ent-progressive-discloure
chmod +x deploy.sh
./deploy.sh
kubectl get gateway,deploy,svc -n agentgateway-system
```
Expected: `agentgateway-proxy` Gateway and deployment are `Available`; `enterprise-agentgateway` and `solo-enterprise-ui` pods Running.

- [ ] **Step 4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add 102-ent-progressive-discloure/deploy.sh 102-ent-progressive-discloure/.env.example
git commit -m "feat(102): deploy.sh part A — enterprise control plane + gateway"
```

---

## Task 3: Deploy synthetic servers + search/default backends (`deploy.sh` Part B)

**Files:**
- Modify: `102-ent-progressive-discloure/deploy.sh` (append Part B before the `# --- Parts ...` marker comment)

**Interfaces:**
- Consumes: kind cluster + Gateway from Task 2; `synthetic-mcp:dev` image from Task 1.
- Produces: 3 Deployments/Services `mcp-server-<count>` in `agentgateway-system`; 6 `EnterpriseAgentgatewayBackend`s named `mcp-<mode>-<count>` and 6 HTTPRoutes exposing `/mcp/<mode>-<count>` (mode ∈ default|search). All routes rewrite the prefix to `/mcp`.

- [ ] **Step 1: Append Part B to `deploy.sh`**

Replace the `# --- Parts B/C/D/E appended in later tasks ---` line with:

```bash
echo ""
echo "==> Step 6: Building + loading synthetic MCP server image..."
docker build -t synthetic-mcp:dev "${SCRIPT_DIR}/mcp-server"
kind load docker-image synthetic-mcp:dev --name "${CLUSTER_NAME}"

echo ""
echo "==> Step 7: Deploying synthetic MCP servers + backends + routes..."
for count in "${TOOL_COUNTS[@]}"; do
  kubectl apply -f- <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-server-${count}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels: { app: mcp-server-${count} }
  template:
    metadata:
      labels: { app: mcp-server-${count} }
    spec:
      containers:
      - name: server
        image: synthetic-mcp:dev
        imagePullPolicy: IfNotPresent
        env:
        - name: TOOL_COUNT
          value: "${count}"
        ports:
        - containerPort: 8000
          name: http
---
apiVersion: v1
kind: Service
metadata:
  name: mcp-server-${count}
  namespace: ${NAMESPACE}
spec:
  selector: { app: mcp-server-${count} }
  ports:
  - name: http
    port: 80
    targetPort: 8000
EOF

  for mode in default search; do
    if [[ "$mode" == "search" ]]; then tool_mode="Search"; else tool_mode="default"; fi
    kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: mcp-${mode}-${count}
  namespace: ${NAMESPACE}
spec:
  entMcp:
    toolMode: ${tool_mode}
    targets:
    - name: synthetic
      static:
        host: mcp-server-${count}.${NAMESPACE}.svc.cluster.local
        port: 80
        protocol: SSE
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-${mode}-${count}
  namespace: ${NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-proxy
    namespace: ${NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp/${mode}-${count}
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /mcp
    backendRefs:
    - name: mcp-${mode}-${count}
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
EOF
  done
done

for count in "${TOOL_COUNTS[@]}"; do
  kubectl rollout status deployment/mcp-server-${count} -n "${NAMESPACE}" --timeout=120s
done
```

- [ ] **Step 2: Run and verify backends/routes exist**

Run:
```bash
cd 102-ent-progressive-discloure
./deploy.sh
kubectl get enterpriseagentgatewaybackend,httproute -n agentgateway-system
kubectl get pods -n agentgateway-system | grep mcp-server
```
Expected: 6 `EnterpriseAgentgatewayBackend`s, 6 HTTPRoutes, 3 `mcp-server-*` pods Running.

- [ ] **Step 3: Verify search vs default tool counts through the gateway**

Run (in one terminal):
```bash
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80
```
In another terminal use the MCP inspector or a JSON-RPC `tools/list`. Quick check with the harness's helper (added in Task 5) is preferred, but a fast manual check:
```bash
# search mode should advertise exactly 2 tools (get_tool, invoke_tool)
# default mode should advertise the full count.
python3 - <<'PY'
import anyio
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
async def count(path):
    async with streamablehttp_client(f"http://localhost:8080{path}") as (r,w,_):
        async with ClientSession(r,w) as s:
            await s.initialize()
            t = await s.list_tools()
            return [x.name for x in t.tools]
async def main():
    print("search-10:", await count("/mcp/search-10"))
    print("default-10:", len(await count("/mcp/default-10")))
asyncio._ = None
anyio.run(main)
PY
```
Expected: `search-10` prints `['get_tool', 'invoke_tool']`; `default-10` prints `10`.
NOTE: If the connection fails, AGW may present the MCP listener over SSE rather than streamable-http — switch the helper to `from mcp.client.sse import sse_client` / `sse_client(url)`. Record whichever transport works; Task 5 uses the same one.

- [ ] **Step 4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add 102-ent-progressive-discloure/deploy.sh
git commit -m "feat(102): deploy.sh part B — synthetic servers + search/default backends"
```

---

## Task 4: OpenAI LLM route (`deploy.sh` Part C + `k8s/openai.yaml`)

**Files:**
- Create: `102-ent-progressive-discloure/k8s/openai.yaml`
- Modify: `102-ent-progressive-discloure/deploy.sh` (append Part C)

**Interfaces:**
- Produces: an OpenAI chat-completions endpoint reachable through the gateway at `/openai`, backed by `gpt-4o-mini`, authed via `openai-secret`.

- [ ] **Step 1: Write `k8s/openai.yaml`**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: agentgateway-system
type: Opaque
stringData:
  Authorization: "__OPENAI_API_KEY__"
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai:
        model: gpt-4o-mini
  policies:
    auth:
      secretRef:
        name: openai-secret
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openai
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agentgateway-proxy
    namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /openai
    backendRefs:
    - name: openai
      group: agentgateway.dev
      kind: AgentgatewayBackend
```

- [ ] **Step 2: Append Part C to `deploy.sh`**

```bash
echo ""
echo "==> Step 8: Configuring OpenAI LLM backend (/openai)..."
sed "s|__OPENAI_API_KEY__|${OPENAI_API_KEY}|" "${SCRIPT_DIR}/k8s/openai.yaml" | kubectl apply -f-
```
(`sed` substitutes the key into a temp stream so the real key never lands in the tracked YAML — matches the repo secret convention.)

- [ ] **Step 3: Run and verify the LLM route**

Run (with proxy port-forwarded to 8080):
```bash
cd 102-ent-progressive-discloure && ./deploy.sh
curl -s "localhost:8080/openai" -H content-type:application/json \
  -d '{"model":"","messages":[{"role":"user","content":"Reply with the single word OK"}]}' | jq '.choices[0].message.content, .usage'
```
Expected: a chat completion whose content contains `OK` and a `usage` object with `prompt_tokens`/`completion_tokens`.

- [ ] **Step 4: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add 102-ent-progressive-discloure/k8s/openai.yaml 102-ent-progressive-discloure/deploy.sh
git commit -m "feat(102): deploy.sh part C — OpenAI LLM route"
```

---

## Task 5: A/B harness

**Files:**
- Create: `102-ent-progressive-discloure/harness/run_ab.py`
- Create: `102-ent-progressive-discloure/harness/pricing.json`
- Create: `102-ent-progressive-discloure/harness/requirements.txt`

**Interfaces:**
- Consumes: gateway at `http://localhost:8080` with MCP routes `/mcp/{default,search}-{10,50,100}` and LLM route `/openai`; the MCP transport confirmed in Task 3.
- Produces: `harness/results.csv`, `harness/results.json`, console summary, and gauges pushed to a Pushgateway at `$PUSHGATEWAY_URL` (default `http://localhost:9091`). CSV columns: `mode,tool_count,run,advertised_tools,first_call_prompt_tokens,total_prompt_tokens,completion_tokens,total_tokens,usd_cost,task_ok`.

- [ ] **Step 1: Write `requirements.txt`**

```
httpx>=0.27
mcp>=1.2.0
prometheus_client>=0.20
```

- [ ] **Step 2: Write `pricing.json`** (gpt-4o-mini list price, USD per 1K tokens)

```json
{
  "gpt-4o-mini": { "input_per_1k": 0.00015, "output_per_1k": 0.0006 }
}
```

- [ ] **Step 3: Write `run_ab.py`**

```python
"""A/B harness proving MCP search mode reduces prompt tokens vs default mode.

For each (mode x tool_count) it connects to the gateway MCP route, lists the
advertised tools, runs an identical task through gpt-4o-mini (via the gateway
/openai route), executes any tool calls back through MCP, and records token
usage + USD cost. Results -> CSV/JSON + Prometheus Pushgateway gauges.
"""
import asyncio
import csv
import json
import os
import pathlib

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

GATEWAY = os.environ.get("GATEWAY_URL", "http://localhost:8080")
LLM_URL = os.environ.get("LLM_URL", f"{GATEWAY}/openai")
PUSHGATEWAY = os.environ.get("PUSHGATEWAY_URL", "http://localhost:9091")
RUNS = int(os.environ.get("RUNS", "5"))
TOOL_COUNTS = [int(x) for x in os.environ.get("TOOL_COUNTS", "10,50,100").split(",")]
MODEL = "gpt-4o-mini"
TASK = (
    "Call the tool named tool_007 with text='hello', number=42, flag=true. "
    "Then reply with exactly the tool's returned string and nothing else."
)
HERE = pathlib.Path(__file__).parent
PRICING = json.loads((HERE / "pricing.json").read_text())[MODEL]


def mcp_tools_to_openai(tools):
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


def cost_usd(prompt_tokens, completion_tokens):
    return (prompt_tokens / 1000.0) * PRICING["input_per_1k"] + \
           (completion_tokens / 1000.0) * PRICING["output_per_1k"]


async def run_one(mode, count, run_idx, client):
    path = f"/mcp/{mode}-{count}"
    async with streamablehttp_client(f"{GATEWAY}{path}") as (r, w, _):
        async with ClientSession(r, w) as session:
            await session.initialize()
            listed = await session.list_tools()
            tools = listed.tools
            openai_tools = mcp_tools_to_openai(tools)

            messages = [{"role": "user", "content": TASK}]
            first_prompt = total_prompt = completion = 0
            task_ok = False

            for _ in range(6):  # bounded tool loop
                resp = (await client.post(LLM_URL, json={
                    "model": "", "temperature": 0, "seed": 42,
                    "messages": messages, "tools": openai_tools,
                })).json()
                usage = resp.get("usage", {})
                p = usage.get("prompt_tokens", 0)
                completion += usage.get("completion_tokens", 0)
                total_prompt += p
                if first_prompt == 0:
                    first_prompt = p

                choice = resp["choices"][0]["message"]
                messages.append(choice)
                calls = choice.get("tool_calls") or []
                if not calls:
                    if "tool_007 echoed" in (choice.get("content") or ""):
                        task_ok = True
                    break
                for call in calls:
                    fn = call["function"]["name"]
                    args = json.loads(call["function"]["arguments"] or "{}")
                    result = await session.call_tool(fn, arguments=args)
                    text = result.content[0].text if result.content else ""
                    if "tool_007 echoed" in text:
                        task_ok = True
                    messages.append({
                        "role": "tool", "tool_call_id": call["id"], "content": text,
                    })

            return {
                "mode": mode, "tool_count": count, "run": run_idx,
                "advertised_tools": len(tools),
                "first_call_prompt_tokens": first_prompt,
                "total_prompt_tokens": total_prompt,
                "completion_tokens": completion,
                "total_tokens": total_prompt + completion,
                "usd_cost": round(cost_usd(total_prompt, completion), 8),
                "task_ok": task_ok,
            }


def push_metrics(rows):
    reg = CollectorRegistry()
    g_first = Gauge("agw_first_call_prompt_tokens", "avg first-call prompt tokens",
                    ["mode", "tool_count"], registry=reg)
    g_total = Gauge("agw_total_tokens", "avg total tokens", ["mode", "tool_count"], registry=reg)
    g_cost = Gauge("agw_usd_cost", "avg USD cost per task", ["mode", "tool_count"], registry=reg)
    g_adv = Gauge("agw_advertised_tools", "tools advertised", ["mode", "tool_count"], registry=reg)
    agg = {}
    for row in rows:
        k = (row["mode"], row["tool_count"])
        agg.setdefault(k, []).append(row)
    for (mode, count), rs in agg.items():
        n = len(rs)
        lbl = {"mode": mode, "tool_count": str(count)}
        g_first.labels(**lbl).set(sum(r["first_call_prompt_tokens"] for r in rs) / n)
        g_total.labels(**lbl).set(sum(r["total_tokens"] for r in rs) / n)
        g_cost.labels(**lbl).set(sum(r["usd_cost"] for r in rs) / n)
        g_adv.labels(**lbl).set(rs[0]["advertised_tools"])
    try:
        push_to_gateway(PUSHGATEWAY, job="agw_progressive_disclosure", registry=reg)
        print(f"Pushed metrics to {PUSHGATEWAY}")
    except Exception as e:
        print(f"WARN: could not push to pushgateway ({e}); CSV/JSON still written")


def print_summary(rows):
    print("\n=== Search-mode savings summary ===")
    agg = {}
    for row in rows:
        k = (row["tool_count"], row["mode"])
        agg.setdefault(k, []).append(row["first_call_prompt_tokens"])
    for count in sorted({r["tool_count"] for r in rows}):
        d = sum(agg[(count, "default")]) / len(agg[(count, "default")])
        s = sum(agg[(count, "search")]) / len(agg[(count, "search")])
        pct = (d - s) / d * 100 if d else 0
        print(f"  {count:>3} tools: default {d:8.0f} tok -> search {s:6.0f} tok "
              f"= {pct:5.1f}% reduction")


async def main():
    rows = []
    async with httpx.AsyncClient(timeout=60) as client:
        for count in TOOL_COUNTS:
            for mode in ("default", "search"):
                for run_idx in range(1, RUNS + 1):
                    row = await run_one(mode, count, run_idx, client)
                    rows.append(row)
                    print(f"{mode}-{count} run {run_idx}: "
                          f"first_prompt={row['first_call_prompt_tokens']} ok={row['task_ok']}")

    (HERE / "results.json").write_text(json.dumps(rows, indent=2))
    with open(HERE / "results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    push_metrics(rows)
    print_summary(rows)

    # sanity assertions
    for row in rows:
        if row["mode"] == "search":
            assert row["advertised_tools"] == 2, f"search advertised {row['advertised_tools']}"
        else:
            assert row["advertised_tools"] == row["tool_count"], "default tool count mismatch"


if __name__ == "__main__":
    asyncio.run(main())
```

- [ ] **Step 4: Smoke-run the harness (fast path)**

Run (proxy port-forwarded to 8080; pushgateway not required yet):
```bash
cd 102-ent-progressive-discloure/harness
python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt
RUNS=1 TOOL_COUNTS=10 python run_ab.py
```
Expected: prints `default-10 run 1` and `search-10 run 1` lines; summary shows a positive % reduction; `results.csv` created; no assertion error. (Pushgateway WARN is acceptable here.)
NOTE: if MCP connection fails, switch `streamablehttp_client` import to `from mcp.client.sse import sse_client` and use `sse_client(url)` per Task 3's note.

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add 102-ent-progressive-discloure/harness
git commit -m "feat(102): A/B token-savings harness"
```

---

## Task 6: Observability stack (`deploy.sh` Part D)

**Files:**
- Create: `102-ent-progressive-discloure/observability/prometheus-values.yaml`
- Create: `102-ent-progressive-discloure/observability/grafana-values.yaml`
- Create: `102-ent-progressive-discloure/observability/dashboard.json`
- Modify: `102-ent-progressive-discloure/deploy.sh` (append Part D)

**Interfaces:**
- Consumes: kind cluster.
- Produces: Prometheus (scraping its bundled Pushgateway) + Grafana (Prometheus datasource + provisioned dashboard) in namespace `observability`. Pushgateway reachable at `localhost:9091` and Grafana at `localhost:3001` after port-forward.

- [ ] **Step 1: Write `observability/prometheus-values.yaml`**

```yaml
# Lightweight Prometheus for kind: server + pushgateway, no alertmanager/node-exporter.
alertmanager:
  enabled: false
prometheus-node-exporter:
  enabled: false
kube-state-metrics:
  enabled: false
prometheus-pushgateway:
  enabled: true
server:
  persistentVolume:
    enabled: false
  global:
    scrape_interval: 5s
```

- [ ] **Step 2: Write `observability/dashboard.json`**

A single-screen narrative dashboard. Panels: (1-3) stat panels for default tokens / search tokens / % reduction; (4) the savings-vs-tool-count time/curve; (5) USD saved per 1k calls. Each panel has a plain-language `description`. Use this content:

```json
{
  "title": "MCP Search Mode — Token & Cost Savings",
  "uid": "agw-progressive-disclosure",
  "schemaVersion": 39,
  "time": { "from": "now-6h", "to": "now" },
  "panels": [
    {
      "id": 1, "type": "stat", "title": "Avg prompt tokens — DEFAULT mode",
      "description": "Tool definitions sent to the model on the first call when ALL tools are advertised. Higher = more wasted context.",
      "gridPos": { "h": 5, "w": 8, "x": 0, "y": 0 },
      "fieldConfig": { "defaults": { "color": { "mode": "fixed", "fixedColor": "red" } } },
      "targets": [ { "expr": "avg(agw_first_call_prompt_tokens{mode=\"default\"})", "legendFormat": "default" } ]
    },
    {
      "id": 2, "type": "stat", "title": "Avg prompt tokens — SEARCH mode",
      "description": "Tool definitions sent when only get_tool + invoke_tool are advertised. Stays flat regardless of backend tool count.",
      "gridPos": { "h": 5, "w": 8, "x": 8, "y": 0 },
      "fieldConfig": { "defaults": { "color": { "mode": "fixed", "fixedColor": "green" } } },
      "targets": [ { "expr": "avg(agw_first_call_prompt_tokens{mode=\"search\"})", "legendFormat": "search" } ]
    },
    {
      "id": 3, "type": "stat", "title": "Prompt-token reduction",
      "description": "How much smaller the model's tool context is with search mode. Bigger is better.",
      "gridPos": { "h": 5, "w": 8, "x": 16, "y": 0 },
      "fieldConfig": { "defaults": { "unit": "percent", "color": { "mode": "thresholds" }, "thresholds": { "steps": [ { "color": "red", "value": null }, { "color": "green", "value": 50 } ] } } },
      "targets": [ { "expr": "(1 - avg(agw_first_call_prompt_tokens{mode=\"search\"}) / avg(agw_first_call_prompt_tokens{mode=\"default\"})) * 100" } ]
    },
    {
      "id": 4, "type": "timeseries", "title": "Prompt tokens vs tool count (the aha curve)",
      "description": "Default rises as the backend exposes more tools; search stays flat. The gap is the saving.",
      "gridPos": { "h": 9, "w": 12, "x": 0, "y": 5 },
      "targets": [
        { "expr": "avg by (tool_count) (agw_first_call_prompt_tokens{mode=\"default\"})", "legendFormat": "default {{tool_count}} tools" },
        { "expr": "avg by (tool_count) (agw_first_call_prompt_tokens{mode=\"search\"})", "legendFormat": "search {{tool_count}} tools" }
      ]
    },
    {
      "id": 5, "type": "bargauge", "title": "Avg USD cost per task by mode & tool count",
      "description": "Real dollar cost per agent task at gpt-4o-mini list prices. Search bars are dramatically shorter.",
      "gridPos": { "h": 9, "w": 12, "x": 12, "y": 5 },
      "fieldConfig": { "defaults": { "unit": "currencyUSD", "decimals": 6 } },
      "targets": [ { "expr": "agw_usd_cost", "legendFormat": "{{mode}} {{tool_count}}" } ]
    }
  ]
}
```

- [ ] **Step 3: Write `observability/grafana-values.yaml`**

```yaml
adminUser: admin
adminPassword: admin
service:
  type: ClusterIP
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      access: proxy
      url: http://prometheus-server.observability.svc.cluster.local
      isDefault: true
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
    - name: default
      orgId: 1
      folder: ""
      type: file
      options:
        path: /var/lib/grafana/dashboards/default
dashboardsConfigMaps:
  default: agw-dashboard
```

- [ ] **Step 4: Append Part D to `deploy.sh`**

```bash
echo ""
echo "==> Step 9: Installing observability (Prometheus + Pushgateway + Grafana)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f-

helm upgrade -i prometheus prometheus-community/prometheus \
  -n observability -f "${SCRIPT_DIR}/observability/prometheus-values.yaml"

# Provision the dashboard JSON as a ConfigMap Grafana auto-loads.
kubectl create configmap agw-dashboard -n observability \
  --from-file=dashboard.json="${SCRIPT_DIR}/observability/dashboard.json" \
  --dry-run=client -o yaml | kubectl apply -f-
kubectl label configmap agw-dashboard -n observability grafana_dashboard=1 --overwrite

helm upgrade -i grafana grafana/grafana \
  -n observability -f "${SCRIPT_DIR}/observability/grafana-values.yaml"

kubectl rollout status deployment/prometheus-server -n observability --timeout=180s || true
kubectl rollout status deployment/grafana -n observability --timeout=180s || true

echo ""
echo "============================================================"
echo " Deployment complete!  Cluster: kind-${CLUSTER_NAME}"
echo "============================================================"
echo " Port-forwards (run each in its own terminal):"
echo "   kubectl port-forward deployment/agentgateway-proxy -n ${NAMESPACE} 8080:80"
echo "   kubectl port-forward svc/prometheus-prometheus-pushgateway -n observability 9091:9091"
echo "   kubectl port-forward svc/grafana -n observability 3001:80"
echo " Then: ./test.sh   (runs the A/B sweep)"
echo " Grafana: http://localhost:3001  (admin/admin)"
```

- [ ] **Step 5: Run and verify Grafana + Pushgateway**

Run:
```bash
cd 102-ent-progressive-discloure && ./deploy.sh
kubectl get pods -n observability
kubectl port-forward svc/prometheus-prometheus-pushgateway -n observability 9091:9091 &
kubectl port-forward svc/grafana -n observability 3001:80 &
sleep 5
curl -s localhost:9091/-/healthy && echo " pushgateway-ok"
curl -s -u admin:admin localhost:3001/api/search | jq '.[].title'
```
Expected: prometheus + grafana + pushgateway pods Running; pushgateway healthy; Grafana search lists `MCP Search Mode — Token & Cost Savings`.
NOTE: confirm the pushgateway service name with `kubectl get svc -n observability | grep pushgateway` and adjust the port-forward / `PUSHGATEWAY_URL` if the chart names it differently.

- [ ] **Step 6: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add 102-ent-progressive-discloure/observability 102-ent-progressive-discloure/deploy.sh
git commit -m "feat(102): deploy.sh part D — Prometheus + Pushgateway + Grafana dashboard"
```

---

## Task 7: `test.sh`, `cleanup.sh`, `step-by-step.sh`

**Files:**
- Create: `102-ent-progressive-discloure/test.sh`
- Create: `102-ent-progressive-discloure/cleanup.sh`
- Create: `102-ent-progressive-discloure/step-by-step.sh`

**Interfaces:**
- Consumes: a deployed cluster + the harness.
- Produces: `test.sh` runs the full sweep and prints the savings summary; `cleanup.sh` deletes the cluster; `step-by-step.sh` is an annotated deploy.

- [ ] **Step 1: Write `test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="agentgateway-system"

echo "==> Port-forwarding proxy (8080), pushgateway (9091)..."
kubectl port-forward deployment/agentgateway-proxy -n "${NAMESPACE}" 8080:80 >/tmp/pf-proxy.log 2>&1 &
PF1=$!
PG_SVC="$(kubectl get svc -n observability -o name | grep pushgateway | head -1 | cut -d/ -f2)"
kubectl port-forward "svc/${PG_SVC}" -n observability 9091:9091 >/tmp/pf-pg.log 2>&1 &
PF2=$!
trap 'kill $PF1 $PF2 2>/dev/null || true' EXIT
sleep 5

echo "==> Running A/B sweep (RUNS=${RUNS:-5})..."
cd "${SCRIPT_DIR}/harness"
[[ -d .venv ]] || { python3 -m venv .venv; . .venv/bin/activate; pip -q install -r requirements.txt; }
. .venv/bin/activate
RUNS="${RUNS:-5}" python run_ab.py

echo ""
echo "==> Ground-truth data written to harness/results.csv"
echo "==> View the dashboard: kubectl port-forward svc/grafana -n observability 3001:80  ->  http://localhost:3001"
```

- [ ] **Step 2: Write `cleanup.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="agw-progressive-disclosure"
echo "==> Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "    Done."
```

- [ ] **Step 3: Write `step-by-step.sh`** (annotated deploy that echoes each command before running it)

```bash
#!/usr/bin/env bash
# Annotated walkthrough of deploy.sh for live demos. Pauses between phases.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run() { echo; echo "+ $*"; read -rp "  [enter to run] "; eval "$*"; }

run "kind get clusters | grep agw-progressive-disclosure || echo 'will be created'"
echo "Now running the full deploy. Each phase is described in deploy.sh."
run "${SCRIPT_DIR}/deploy.sh"
echo "Compare advertised tool counts (the whole point):"
run "echo 'default exposes all tools; search exposes only get_tool + invoke_tool'"
run "${SCRIPT_DIR}/test.sh"
echo "Open Grafana to see the savings curve: http://localhost:3001 (admin/admin)"
```

- [ ] **Step 4: Make executable, run end-to-end, verify summary**

Run:
```bash
cd 102-ent-progressive-discloure
chmod +x test.sh cleanup.sh step-by-step.sh
RUNS=3 ./test.sh
```
Expected: the summary prints three lines (10/50/100 tools) each with a positive % reduction; `harness/results.csv` populated with 18 rows (3 counts × 2 modes × 3 runs).

- [ ] **Step 5: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add 102-ent-progressive-discloure/test.sh 102-ent-progressive-discloure/cleanup.sh 102-ent-progressive-discloure/step-by-step.sh
git commit -m "feat(102): test/cleanup/step-by-step scripts"
```

---

## Task 8: README

**Files:**
- Create: `102-ent-progressive-discloure/README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the demo's documentation.

- [ ] **Step 1: Write `README.md`**

Include these sections with real content:
- **Title + one-paragraph concept**: progressive disclosure / search mode replaces the full MCP tool list with `get_tool` + `invoke_tool`, shrinking the model's tool-context.
- **Architecture diagram**: copy the ASCII diagram from the design spec (`docs/superpowers/specs/2026-06-19-progressive-disclosure-search-mode-design.md`).
- **Prerequisites**: kind, kubectl, helm, docker, python3; `AGENTGATEWAY_LICENSE_KEY`, `OPENAI_API_KEY`.
- **Quick start**:
  ```bash
  cp .env.example .env   # fill in keys, then: set -a; . .env; set +a
  ./deploy.sh
  ./test.sh
  # Grafana: kubectl port-forward svc/grafana -n observability 3001:80  -> http://localhost:3001 (admin/admin)
  ./cleanup.sh
  ```
- **What the data proves**: explain `results.csv` columns and that `first_call_prompt_tokens` isolates tool-definition overhead; note search mode stays flat as tool count grows.
- **Key config**: show the `EnterpriseAgentgatewayBackend` snippet with `entMcp.toolMode: Search` and link the Solo docs (https://docs.solo.io/agentgateway/latest/mcp/tool-mode/search-mode/).
- **Cluster/version table row**: cluster `agw-progressive-disclosure`, AGW `v2026.6.1` (matches the CLAUDE.md convention table).

- [ ] **Step 2: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add 102-ent-progressive-discloure/README.md
git commit -m "docs(102): README for progressive disclosure demo"
```

---

## Task 9 (stretch): Live gateway-emitted GenAI metrics corroboration

**Files:**
- Modify: `102-ent-progressive-discloure/deploy.sh` (optional Part E)
- Modify: `102-ent-progressive-discloure/observability/prometheus-values.yaml`

**Interfaces:**
- Consumes: running control plane + Prometheus.
- Produces: AgentGateway's own GenAI token telemetry scraped into the same Prometheus, as an independent second source corroborating the harness numbers.

This task is optional and depends on the enterprise telemetry surface, which must be confirmed against the running build rather than assumed.

- [ ] **Step 1: Discover what the control plane / data plane exposes**

Run:
```bash
helm show values oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway --version v2026.6.1 | grep -iA3 -e telemetry -e metrics -e otlp -e tracing || true
kubectl get svc -n agentgateway-system
# probe likely Prometheus endpoints on the data plane:
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 15020:15020 >/dev/null 2>&1 &
curl -s localhost:15020/metrics | grep -i -e gen_ai -e token | head || echo "no native token metric on :15020"
```
Expected: identifies whether AGW exposes a Prometheus `/metrics` endpoint with GenAI/token series, and on which port.

- [ ] **Step 2: If a metrics endpoint exists, add a scrape job**

Add to `prometheus-values.yaml` under `server.extraScrapeConfigs` (substitute the confirmed port/path):
```yaml
server:
  extraScrapeConfigs: |
    - job_name: agentgateway
      kubernetes_sd_configs:
        - role: pod
          namespaces: { names: [agentgateway-system] }
      relabel_configs:
        - source_labels: [__meta_kubernetes_pod_label_app]
          regex: agentgateway-proxy
          action: keep
```
Then `helm upgrade -i prometheus prometheus-community/prometheus -n observability -f observability/prometheus-values.yaml`.

- [ ] **Step 3: If no Prometheus endpoint exists (OTLP-only)**

Document in the README that AGW's native telemetry is OTLP-only here and the harness Pushgateway is the authoritative source; do not fabricate a collector pipeline. Stop — the proof from Tasks 1–8 stands on its own.

- [ ] **Step 4: Commit (only if a working scrape was added)**

```bash
cd "$(git rev-parse --show-toplevel)"
git add 102-ent-progressive-discloure/observability/prometheus-values.yaml 102-ent-progressive-discloure/deploy.sh
git commit -m "feat(102): scrape gateway-native GenAI metrics as corroboration"
```

---

## Self-Review notes

- **Spec coverage:** A/B live LLM proof → Task 5; synthetic tool-count knob (10/50/100) → Tasks 1,3; OpenAI via gateway → Task 4; Prometheus+Grafana, simple/self-explanatory dashboard → Task 6 (panel descriptions, 5 panels, single screen); results.csv/json ground truth → Task 5; standard scripts → Tasks 2-4,6,7; README → Task 8; AGW-native metrics corroboration → Task 9 (stretch, honestly gated on discovery).
- **Determinism:** temperature=0, seed=42, echo-only tools, RUNS≥5 default; assertions on advertised tool counts.
- **Honest uncertainty surfaced, not faked:** MCP client transport (streamable-http vs SSE) has a verify-and-switch note in Tasks 3 & 5; the gateway-native telemetry path is a discovery-gated stretch task rather than invented config. These are the two genuine unknowns; everything else is concrete.
```
