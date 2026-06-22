#!/usr/bin/env bash
set -euo pipefail
##############################################################################
# deploy.sh — 105: AGW tool modes vs/with Headroom (do they STACK?)
#
# Same workload as demo 104 (GitHub's REMOTE MCP fronted by AgentGateway in
# Standard / Search / Code tool modes), plus a SECOND, independent knob:
# Headroom (https://github.com/headroomlabs-ai/headroom), a local compression
# proxy that shrinks the content payload (tool-result JSON + history) before it
# reaches the LLM. AGW shrinks the tool CATALOG; Headroom shrinks the PAYLOAD —
# different layers, so the question is whether the savings stack.
#
# Builds:
#   kind cluster + Enterprise AgentGateway + Gateway + OpenAI LLM backend
#   + gh-std / gh-search / gh-code backends pointing at the external GitHub MCP
#   + installs the Headroom proxy into the harness venv (launched at run time by
#     run_matrix.sh / test.sh, not held open here).
#
# Prereqs: kind, kubectl, helm, python3 >= 3.10
#   env: AGENTGATEWAY_LICENSE_KEY, OPENAI_API_KEY, GITHUB_PAT
##############################################################################

CLUSTER_NAME="${CLUSTER_NAME:-agw-headroom-comp}"
NAMESPACE="agentgateway-system"
AGW_VERSION="v2026.6.1"
GATEWAY_API_VERSION="v1.5.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Checking prerequisites..."
for c in kind kubectl helm; do command -v "$c" &>/dev/null || { echo "ERROR: '$c' required." >&2; exit 1; }; done
[[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || { echo "ERROR: AGENTGATEWAY_LICENSE_KEY not set." >&2; exit 1; }
[[ -n "${OPENAI_API_KEY:-}" ]] || { echo "ERROR: OPENAI_API_KEY not set." >&2; exit 1; }
[[ -n "${GITHUB_PAT:-}" ]] || { echo "ERROR: GITHUB_PAT not set (see .env.example)." >&2; exit 1; }

echo ""
echo "==> Step 1: kind cluster '${CLUSTER_NAME}'..."
kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$" || kind create cluster --name "${CLUSTER_NAME}"
kubectl config use-context "kind-${CLUSTER_NAME}"
kubectl wait --for=condition=Ready node --all --timeout=120s

echo ""
echo "==> Step 2: Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo ""
echo "==> Step 3: Enterprise AgentGateway CRDs + control plane (${AGW_VERSION})..."
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" --version "${AGW_VERSION}"
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "${NAMESPACE}" --version "${AGW_VERSION}" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}"
kubectl rollout status deployment/enterprise-agentgateway -n "${NAMESPACE}" --timeout=180s

echo ""
echo "==> Step 4: agentgateway-proxy Gateway..."
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: agentgateway-proxy, namespace: ${NAMESPACE} }
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
  - { protocol: HTTP, port: 80, name: http, allowedRoutes: { namespaces: { from: All } } }
EOF
kubectl wait --for=condition=Available deployment/agentgateway-proxy -n "${NAMESPACE}" --timeout=300s

echo ""
echo "==> Step 5: OpenAI LLM backend (/openai)..."
sed "s|__OPENAI_API_KEY__|${OPENAI_API_KEY}|" "${SCRIPT_DIR}/k8s/openai.yaml" | kubectl apply -f-

echo ""
echo "==> Step 6: GitHub external MCP backends (Standard/Search/Code) + PAT secret..."
sed "s|__GITHUB_PAT__|${GITHUB_PAT}|" "${SCRIPT_DIR}/k8s/github.yaml" | kubectl apply -f-

echo ""
echo "==> Step 7: Headroom compression proxy — install into the harness venv..."
# Headroom is a LOCAL proxy (data stays on-device by design). We install it into
# the same venv the harness uses, then launch it at run time (run_matrix.sh /
# test.sh) pointed at the AGW /openai route as its upstream.
HR_VENV="${SCRIPT_DIR}/harness/.venv"
pick_python() {
  for p in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 \
           python3.13 python3.12 python3.11 python3.10 python3; do
    command -v "$p" >/dev/null 2>&1 || continue
    "$p" -c 'import sys; sys.exit(0 if sys.version_info[:2]>=(3,10) else 1)' 2>/dev/null \
      && { command -v "$p"; return; }
  done
  echo "ERROR: need a working Python >= 3.10" >&2; exit 1
}
PY="$(pick_python)"
[[ -d "${HR_VENV}" ]] || "${PY}" -m venv "${HR_VENV}"
"${HR_VENV}/bin/python" -m pip install -q --upgrade pip
"${HR_VENV}/bin/python" -m pip install -q -r "${SCRIPT_DIR}/harness/requirements.txt"
echo "    Installing headroom-ai[all] (pulls ML models; first run is slow)..."
"${HR_VENV}/bin/python" -m pip install -q 'headroom-ai[all]' || {
  echo "    WARN: 'headroom-ai[all]' install failed. Confirm the package/extra names" >&2
  echo "          with: ${HR_VENV}/bin/pip install 'headroom-ai[all]'" >&2
}

echo ""
echo "============================================================"
echo " 105 Headroom comparison ready.  Cluster: kind-${CLUSTER_NAME}"
echo "============================================================"
echo " Smoke test one question, Headroom OFF vs ON:"
echo "   ./test.sh"
echo ""
echo " Run the full 12-cell matrix (3 modes x OFF/ON x 2 repos) + quality judge:"
echo "   REPO_LARGE=owner/big-readonly-repo ./run_matrix.sh"
echo ""
echo " NOTE: Headroom ships with compression OFF by default. run_matrix.sh / test.sh"
echo "       launch it with compression EXPLICITLY enabled — otherwise the ON column"
echo "       would equal the OFF column and the comparison would be meaningless."
echo ""
