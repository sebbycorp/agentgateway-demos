#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# deploy.sh — Deploy AgentGateway Virtual Keys Demo
#
# Deploys a kind cluster with AgentGateway configured for:
#   1. API key authentication (virtual keys for Alice & Bob)
#   2. Per-key daily token budgets (100K tokens/day)
#   3. OpenAI backend on /openai
#
# Prerequisites:
#   - kind, kubectl, helm, jq installed
#   - OPENAI_API_KEY environment variable set
##############################################################################

CLUSTER_NAME="agw-series"
NAMESPACE="agentgateway-system"
AGW_VERSION="v1.1.0"
GATEWAY_API_VERSION="v1.5.0"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
echo "==> Checking prerequisites..."

for cmd in kind kubectl helm jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "ERROR: OPENAI_API_KEY environment variable is not set." >&2
  exit 1
fi

echo "    All prerequisites met."

# ---------------------------------------------------------------------------
# Step 1: Create kind cluster
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 1: Creating kind cluster '${CLUSTER_NAME}'..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "    Cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  kind create cluster --name "${CLUSTER_NAME}"
fi

# ---------------------------------------------------------------------------
# Step 2: Install Gateway API CRDs
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 2: Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."

kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# ---------------------------------------------------------------------------
# Step 3: Install AgentGateway via Helm
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 3: Installing AgentGateway CRDs and control plane (${AGW_VERSION})..."

helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always

helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait

# ---------------------------------------------------------------------------
# Step 4: Wait for pods to be ready
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 4: Waiting for AgentGateway pods to be ready..."

kubectl wait --for=condition=Ready pods --all -n "${NAMESPACE}" --timeout=120s
kubectl get pods -n "${NAMESPACE}"

# ---------------------------------------------------------------------------
# Step 5: Create the Gateway listener
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 5: Creating Gateway listener on port 80..."

kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF

# ---------------------------------------------------------------------------
# Step 6: Create API key secrets
#
# Three secrets:
#   - openai-secret: Provider API key for outbound LLM requests
#   - user-alice-key: Virtual key for user Alice
#   - user-bob-key: Virtual key for user Bob
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 6: Creating API key secrets (provider + virtual keys)..."

kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  Authorization: "${OPENAI_API_KEY}"
---
apiVersion: v1
kind: Secret
metadata:
  name: user-alice-key
  namespace: ${NAMESPACE}
  labels:
    api-key-group: llm-users
type: extauth.solo.io/apikey
stringData:
  api-key: sk-alice-abc123def456
---
apiVersion: v1
kind: Secret
metadata:
  name: user-bob-key
  namespace: ${NAMESPACE}
  labels:
    api-key-group: llm-users
type: extauth.solo.io/apikey
stringData:
  api-key: sk-bob-xyz789uvw012
EOF

# ---------------------------------------------------------------------------
# Step 7: Create API key authentication policy
#
# Requires all requests to include a valid Bearer token from the
# llm-users key group. Invalid or missing keys get 401.
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 7: Creating API key authentication policy..."

kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: api-key-auth
  namespace: ${NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-proxy
  traffic:
    apiKeyAuthentication:
      mode: Strict
      secretSelector:
        matchLabels:
          api-key-group: llm-users
EOF

# ---------------------------------------------------------------------------
# Step 8: Deploy rate limit infrastructure
#
# Redis for counter storage + Envoy rate limit server for budget enforcement.
# ConfigMap defines 100K tokens/day per user.
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 8: Deploying rate limit infrastructure (Redis + server + config)..."

kubectl apply -f- <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: rate-limit-config
  namespace: ${NAMESPACE}
data:
  config.yaml: |
    domain: token-budgets
    descriptors:
    - key: user_id
      rate_limit:
        unit: day
        requests_per_unit: 100000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ${NAMESPACE}
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rate-limit-server
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rate-limit-server
  template:
    metadata:
      labels:
        app: rate-limit-server
    spec:
      containers:
      - name: ratelimit
        image: envoyproxy/ratelimit:master
        ports:
        - containerPort: 8081
          name: grpc
        env:
        - name: RUNTIME_ROOT
          value: /data
        - name: RUNTIME_SUBDIRECTORY
          value: ratelimit
        - name: REDIS_SOCKET_TYPE
          value: tcp
        - name: REDIS_URL
          value: redis:6379
        - name: USE_STATSD
          value: "false"
        - name: LOG_LEVEL
          value: debug
        volumeMounts:
        - name: config
          mountPath: /data/ratelimit/config/config.yaml
          subPath: config.yaml
      volumes:
      - name: config
        configMap:
          name: rate-limit-config
---
apiVersion: v1
kind: Service
metadata:
  name: rate-limit-server
  namespace: ${NAMESPACE}
spec:
  selector:
    app: rate-limit-server
  ports:
  - port: 8081
    targetPort: 8081
    name: grpc
EOF

echo "    Waiting for rate limit pods..."
kubectl wait --for=condition=Ready pods -l app=redis -n "${NAMESPACE}" --timeout=120s
kubectl wait --for=condition=Ready pods -l app=rate-limit-server -n "${NAMESPACE}" --timeout=120s

# ---------------------------------------------------------------------------
# Step 9: Create per-key token budget policy
#
# Enforces daily token budgets per user using the X-User-ID header.
# Uses global rate limiting backed by the Envoy rate limit server.
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 9: Creating per-key token budget policy (100K tokens/day)..."

kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: daily-token-budget
  namespace: ${NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-proxy
  traffic:
    rateLimit:
      global:
        domain: token-budgets
        backendRef:
          kind: Service
          name: rate-limit-server
          namespace: ${NAMESPACE}
          port: 8081
        descriptors:
        - entries:
          - name: user_id
            expression: 'request.headers["x-user-id"]'
          unit: Tokens
EOF

# ---------------------------------------------------------------------------
# Step 10: Create OpenAI backend
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 10: Creating OpenAI backend (gpt-5.4-mini)..."

kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai-backend
  namespace: ${NAMESPACE}
spec:
  ai:
    groups:
      - providers:
          - name: openai-gpt4
            openai:
              model: gpt-5.4-mini
            policies:
              auth:
                secretRef:
                  name: openai-secret
EOF

# ---------------------------------------------------------------------------
# Step 11: Create HTTPRoute for /openai
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 11: Creating HTTPRoute for /openai..."

kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openai-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: ${NAMESPACE}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /openai
      backendRefs:
        - name: openai-backend
          namespace: ${NAMESPACE}
          group: agentgateway.dev
          kind: AgentgatewayBackend
EOF

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Deployment complete!"
echo "============================================================"
echo ""
echo " Virtual Keys:"
echo "   Alice: sk-alice-abc123def456  (100K tokens/day)"
echo "   Bob:   sk-bob-xyz789uvw012    (100K tokens/day)"
echo ""
echo " Endpoint:"
echo "   /openai  — Authenticated via virtual API keys -> OpenAI gpt-5.4-mini"
echo ""
echo " To port-forward the gateway:"
echo "   kubectl port-forward -n ${NAMESPACE} svc/agentgateway-proxy 8080:80"
echo ""
echo " Then test with:"
echo "   ./test.sh"
echo ""
