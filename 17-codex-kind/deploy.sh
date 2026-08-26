#!/usr/bin/env bash
# OSS AgentGateway on kind -> OpenAI, with Entra JWT on the inbound path.
# Codex on the laptop port-forwards to the in-cluster proxy.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME="${CLUSTER_NAME:-agw-codex}"
NAMESPACE="agentgateway-system"
AGW_VERSION="${AGW_VERSION:-v1.4.1}"
GATEWAY_API_VERSION="v1.5.0"

# Optional local env (gitignored). Fall back to 14-codex if this demo has none yet.
if [[ -f ./.env.entra ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.entra
  set +a
elif [[ -f ../14-codex/.env.entra ]]; then
  echo "==> Loading Entra settings from ../14-codex/.env.entra"
  set -a
  # shellcheck disable=SC1091
  . ../14-codex/.env.entra
  set +a
fi

echo "==> Checking prerequisites..."
for cmd in kind kubectl helm jq; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' is required." >&2; exit 1; }
done
: "${OPENAI_API_KEY:?ERROR: OPENAI_API_KEY is not set.}"
: "${ENTRA_TENANT_ID:?ERROR: ENTRA_TENANT_ID is not set. Copy .env.example to .env.entra or export it.}"
: "${ENTRA_CLIENT_ID:?ERROR: ENTRA_CLIENT_ID is not set. Copy .env.example to .env.entra or export it.}"
echo "    All prerequisites met."

# --- cluster (idempotent) ---
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "==> Creating kind cluster $CLUSTER_NAME"
  kind create cluster --name "$CLUSTER_NAME"
else
  echo "==> kind cluster $CLUSTER_NAME exists"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

# --- Gateway API CRDs + AgentGateway ---
echo "==> Gateway API CRDs $GATEWAY_API_VERSION"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> AgentGateway $AGW_VERSION"
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace -n "$NAMESPACE" --version "$AGW_VERSION"
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  -n "$NAMESPACE" --version "$AGW_VERSION" --wait --timeout 5m

echo "==> Waiting for AgentGateway pods..."
kubectl wait --for=condition=Ready pods --all -n "$NAMESPACE" --timeout=180s
kubectl get pods -n "$NAMESPACE"

# --- Gateway ---
echo "==> Creating Gateway listener on port 80..."
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: agentgateway
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF

# --- Secret ---
echo "==> Creating OpenAI API key secret..."
kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  Authorization: "${OPENAI_API_KEY}"
EOF

# --- Backend ---
# No pinned model: Codex (and curl) send the model on each request.
# Route map is required so /v1/responses is handled as Responses, not Completions.
# v1.4.1 returns 501 for RouteType Models; passthrough the probe to OpenAI instead.
echo "==> Creating OpenAI backend..."
kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai
  namespace: ${NAMESPACE}
spec:
  ai:
    provider:
      openai: {}
  policies:
    auth:
      secretRef:
        name: openai-secret
    ai:
      routes:
        "/v1/responses": "Responses"
        "/v1/chat/completions": "Completions"
        "/v1/models": "Passthrough"
        "*": "Passthrough"
EOF

# --- Route ---
echo "==> Creating HTTPRoute for /v1 -> OpenAI backend..."
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openai
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: ${NAMESPACE}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - name: openai
          namespace: ${NAMESPACE}
          group: agentgateway.dev
          kind: AgentgatewayBackend
EOF

# --- Entra JWT ---
# v1.4.1 has no jwks.remote.url. Remote JWKS is a static Backend + jwksPath.
# audiences MUST be the appId GUID, not api://agw-codex-demo.
# The inbound Entra token is stripped after validation; the OpenAI key is injected
# by the backend auth policy above.
echo "==> Creating Entra JWKS backend (login.microsoftonline.com:443)..."
kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: entra-jwks
  namespace: ${NAMESPACE}
spec:
  static:
    host: login.microsoftonline.com
    port: 443
  policies:
    tls: {}
EOF

echo "==> Creating Entra JWT policy (issuer=$ENTRA_TENANT_ID audience=$ENTRA_CLIENT_ID)..."
kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: entra-jwt
  namespace: ${NAMESPACE}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agentgateway-proxy
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: https://login.microsoftonline.com/${ENTRA_TENANT_ID}/v2.0
          audiences:
            - ${ENTRA_CLIENT_ID}
          jwks:
            remote:
              jwksPath: /${ENTRA_TENANT_ID}/discovery/v2.0/keys
              backendRef:
                name: entra-jwks
                kind: AgentgatewayBackend
                group: agentgateway.dev
                port: 443
  frontend:
    accessLog:
      attributes:
        add:
          - name: agentgateway.user
            expression: 'has(jwt.email) ? jwt.email : (has(jwt.preferred_username) ? jwt.preferred_username : jwt.sub)'
          - name: agentgateway.group
            expression: 'has(jwt.roles) ? jwt.roles[0] : (has(jwt.groups) ? jwt.groups[0] : "unassigned")'
EOF

echo "==> Waiting for Gateway to be programmed..."
kubectl wait --for=condition=Programmed gateway/agentgateway-proxy \
  -n "$NAMESPACE" --timeout=180s || true
kubectl get gateway,httproute,agentgatewaybackend,agentgatewaypolicy -n "$NAMESPACE"

cat <<EOM

============================================================
 Deployment complete!
============================================================

 Cluster:   kind-${CLUSTER_NAME}
 Version:   AgentGateway ${AGW_VERSION}
 Namespace: ${NAMESPACE}

 Port-forward the proxy, then point Codex at it:

   kubectl port-forward -n ${NAMESPACE} svc/agentgateway-proxy 8080:80

 Codex ~/.codex/config.toml:

   model_provider = "agentgateway"
   [model_providers.agentgateway]
   name = "OpenAI via agentgateway (kind)"
   base_url = "http://localhost:8080/v1"
   wire_api = "responses"
   [model_providers.agentgateway.auth]
   command = "$(pwd)/entra-token.sh"
   args = []
   timeout_ms = 60000
   refresh_interval_ms = 1800000

 Test:

   az login   # once, if needed
   ./test.sh

 Cleanup:

   ./cleanup.sh
EOM
