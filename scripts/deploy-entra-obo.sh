#!/usr/bin/env bash
set -euo pipefail

#───────────────────────────────────────────────────────────────────────────────
# deploy-entra-obo.sh
#
# Deploys the Microsoft Entra ID OBO Token Exchange demo on an existing
# Enterprise Agentgateway installation (created by setup-kind.sh).
#
# Required env vars:
#   ENTRA_TENANT_ID              — Azure AD tenant ID
#   ENTRA_MIDDLETIER_CLIENT_ID   — Middle-tier app registration client ID
#   ENTRA_DOWNSTREAM_SCOPE       — Downstream API scope (e.g. api://<id>/.default)
#   ENTRA_OBO_CLIENT_SECRET      — Client secret for the middle-tier app
#   SOLO_TRIAL_LICENSE_KEY       — Solo license key
#
# Optional:
#   ENTERPRISE_AGW_VERSION       — Chart version (default: v2.2.0)
#───────────────────────────────────────────────────────────────────────────────

ENTERPRISE_AGW_VERSION="${ENTERPRISE_AGW_VERSION:-v2.2.0}"

# ── Validate required env vars ────────────────────────────────────────────────
for var in ENTRA_TENANT_ID ENTRA_MIDDLETIER_CLIENT_ID ENTRA_DOWNSTREAM_SCOPE ENTRA_OBO_CLIENT_SECRET SOLO_TRIAL_LICENSE_KEY; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} must be set."
    exit 1
  fi
done

echo "=== Step 1/7: Upgrading controller with Entra OBO token exchange config ==="
helm upgrade -i -n agentgateway-system enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --create-namespace \
  --version "${ENTERPRISE_AGW_VERSION}" \
  --set-string licensing.licenseKey="${SOLO_TRIAL_LICENSE_KEY}" \
  -f -<<EOF
gatewayClassParametersRefs:
  enterprise-agentgateway:
    group: enterpriseagentgateway.solo.io
    kind: EnterpriseAgentgatewayParameters
    name: agentgateway-config
    namespace: agentgateway-system
tokenExchange:
  enabled: true
  issuer: "enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777"
  tokenExpiration: 24h
  subjectValidator:
    validatorType: remote
    remoteConfig:
      url: "https://login.microsoftonline.com/${ENTRA_TENANT_ID}/discovery/v2.0/keys"
  apiValidator:
    validatorType: remote
    remoteConfig:
      url: "https://login.microsoftonline.com/${ENTRA_TENANT_ID}/discovery/v2.0/keys"
  actorValidator:
    validatorType: k8s
  elicitation:
    secretName: ""
EOF

echo "Waiting for controller rollout..."
kubectl rollout status deployment/enterprise-agentgateway -n agentgateway-system --timeout=120s

echo "Verifying port 7777 on controller service..."
kubectl get svc -n agentgateway-system enterprise-agentgateway

echo "Verifying token exchange server in logs..."
kubectl logs -n agentgateway-system deploy/enterprise-agentgateway --tail=50 | grep -i token || true

echo ""
echo "=== Step 2/7: Creating Entra client secret ==="
kubectl create secret generic entra-obo-client-secret \
  -n agentgateway-system \
  --from-literal=client_secret="${ENTRA_OBO_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== Step 3/7: Patching gateway config with STS parameters ==="
kubectl patch enterpriseagentgatewayparameters agentgateway-config \
  -n agentgateway-system \
  --type=merge \
  -p '{"spec":{"env":[{"name":"STS_URI","value":"http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth2/token"},{"name":"STS_AUTH_TOKEN","value":"./var/run/secrets/xds-tokens/xds-token"}]}}'

echo "Verifying STS env vars..."
kubectl get enterpriseagentgatewayparameters agentgateway-config \
  -n agentgateway-system -o jsonpath='{.spec.env}' | jq .

echo ""
echo "=== Step 4/7: Deploying JWKS backend (Entra) ==="
kubectl apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: entra-jwks
  namespace: agentgateway-system
spec:
  static:
    host: login.microsoftonline.com
    port: 443
  policies:
    tls: {}
EOF

echo ""
echo "=== Step 5/7: Deploying httpbin demo backend and HTTPRoute ==="
kubectl apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: obo-demo-backend
  namespace: agentgateway-system
spec:
  static:
    host: httpbin.agentgateway-system.svc.cluster.local
    port: 8000
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jwt-secure-obo
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: obo-demo-backend
          group: agentgateway.dev
          kind: AgentgatewayBackend
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
  namespace: agentgateway-system
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: agentgateway-system
  labels:
    app: httpbin
    service: httpbin
spec:
  ports:
    - name: http
      port: 8000
      targetPort: 8080
  selector:
    app: httpbin
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: agentgateway-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
        - image: docker.io/mccutchen/go-httpbin:v2.15.0
          imagePullPolicy: IfNotPresent
          name: httpbin
          ports:
            - containerPort: 8080
EOF

echo "Waiting for httpbin pod..."
kubectl rollout status deployment/httpbin -n agentgateway-system --timeout=120s

echo ""
echo "=== Step 6/7: Applying JWT authentication policy ==="
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: jwt-secure-obo-policy
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: jwt-secure-obo
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: https://sts.windows.net/${ENTRA_TENANT_ID}/
          audiences:
            - "api://${ENTRA_MIDDLETIER_CLIENT_ID}"
          jwks:
            remote:
              jwksPath: /${ENTRA_TENANT_ID}/discovery/v2.0/keys
              backendRef:
                name: entra-jwks
                kind: AgentgatewayBackend
                group: agentgateway.dev
                port: 443
EOF

echo ""
echo "=== Step 7/7: Applying Entra OBO token exchange policy ==="
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: obo-demo-entra-obo
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: obo-demo-backend
  backend:
    tokenExchange:
      mode: ExchangeOnly
      entra:
        tenantId: "${ENTRA_TENANT_ID}"
        clientId: "${ENTRA_MIDDLETIER_CLIENT_ID}"
        scope: "${ENTRA_DOWNSTREAM_SCOPE}"
        clientSecretRef:
          name: entra-obo-client-secret
          key: client_secret
EOF

echo ""
echo "======================================"
echo " Entra OBO demo deployed successfully!"
echo ""
echo " Gateway URL: http://localhost:8080"
echo ""
echo " Next: run test-entra-obo.sh to test"
echo "======================================"
kubectl get pods -n agentgateway-system
