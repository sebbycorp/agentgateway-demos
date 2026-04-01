#!/usr/bin/env bash
set -euo pipefail

#───────────────────────────────────────────────────────────────────────────────
# cleanup-entra-obo.sh
#
# Removes all resources created by the Entra OBO demo and restores the
# controller to its original configuration (no tokenExchange).
#
# Required env vars:
#   SOLO_TRIAL_LICENSE_KEY
#
# Optional:
#   ENTERPRISE_AGW_VERSION (default: v2.2.0)
#───────────────────────────────────────────────────────────────────────────────

ENTERPRISE_AGW_VERSION="${ENTERPRISE_AGW_VERSION:-v2.2.0}"

if [[ -z "${SOLO_TRIAL_LICENSE_KEY:-}" ]]; then
  echo "ERROR: SOLO_TRIAL_LICENSE_KEY must be set."
  exit 1
fi

echo "=== Cleaning up Entra OBO demo resources ==="

echo "Deleting policies..."
kubectl delete enterpriseagentgatewaypolicy -n agentgateway-system jwt-secure-obo-policy obo-demo-entra-obo --ignore-not-found

echo "Deleting route and backends..."
kubectl delete httproute -n agentgateway-system jwt-secure-obo --ignore-not-found
kubectl delete agentgatewaybackend -n agentgateway-system obo-demo-backend entra-jwks --ignore-not-found

echo "Deleting httpbin..."
kubectl delete deployment -n agentgateway-system httpbin --ignore-not-found
kubectl delete service -n agentgateway-system httpbin --ignore-not-found
kubectl delete serviceaccount -n agentgateway-system httpbin --ignore-not-found

echo "Removing STS env vars from gateway config..."
kubectl patch enterpriseagentgatewayparameters agentgateway-config \
  -n agentgateway-system \
  --type=merge \
  -p '{"spec":{"env":null}}'

echo "Deleting Entra client secret..."
kubectl delete secret -n agentgateway-system entra-obo-client-secret --ignore-not-found

echo "Restoring controller to original config (no tokenExchange)..."
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
EOF

echo "Waiting for controller rollout..."
kubectl rollout status deployment/enterprise-agentgateway -n agentgateway-system --timeout=120s

echo ""
echo "======================================"
echo " Cleanup complete."
echo "======================================"
kubectl get pods -n agentgateway-system
