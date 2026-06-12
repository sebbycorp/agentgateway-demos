#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# configure-observability.sh — Wire AgentGateway tracing to the in-cluster
#                              Langfuse for cost analysis.
#
# Run this AFTER you have created a project in the Langfuse UI and have the
# project Public Key + Secret Key.
#
# Usage:
#   export LANGFUSE_PUBLIC_KEY=pk-lf-...
#   export LANGFUSE_SECRET_KEY=sk-lf-...
#   ./configure-observability.sh
#
# Or pass as arguments:
#   ./configure-observability.sh pk-lf-... sk-lf-...
#
# The script:
#   - Computes the Basic auth value that Langfuse OTLP expects
#   - Applies (or updates) the AgentgatewayParameters resource with a
#     complete tracing section pointing at the internal Langfuse service
#   - Prints instructions to force the data-plane proxies to pick up the
#     new config (controller-driven)
##############################################################################

AGW_NAMESPACE="agentgateway-system"
PARAM_NAME="agw-params"

if [[ $# -ge 2 ]]; then
  LANGFUSE_PUBLIC_KEY="$1"
  LANGFUSE_SECRET_KEY="$2"
fi

if [[ -z "${LANGFUSE_PUBLIC_KEY:-}" || -z "${LANGFUSE_SECRET_KEY:-}" ]]; then
  echo "ERROR: LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY must be set (or passed as arguments)." >&2
  echo "Example:" >&2
  echo "  export LANGFUSE_PUBLIC_KEY=pk-lf-..." >&2
  echo "  export LANGFUSE_SECRET_KEY=sk-lf-..." >&2
  echo "  ./configure-observability.sh" >&2
  exit 1
fi

# Build the exact auth string Langfuse expects for its /api/public/otel endpoint.
# Format: "Basic <base64(public:secret)>"
AUTH_STRING=$(printf '%s:%s' "${LANGFUSE_PUBLIC_KEY}" "${LANGFUSE_SECRET_KEY}" | base64 | tr -d '\n')

echo "==> Configuring AgentGateway tracing → Langfuse (in-cluster)"
echo "    Public key prefix: ${LANGFUSE_PUBLIC_KEY:0:12}..."
echo "    Langfuse internal endpoint: http://langfuse-web.langfuse.svc.cluster.local:3000/api/public/otel/v1/traces"

kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayParameters
metadata:
  name: ${PARAM_NAME}
  namespace: ${AGW_NAMESPACE}
spec:
  rawConfig:
    config:
      tracing:
        # Direct OTLP/HTTP to Langfuse (gRPC not supported by Langfuse ingest at the time of writing).
        otlpEndpoint: http://langfuse-web.langfuse.svc.cluster.local:3000/api/public/otel/v1/traces
        otlpProtocol: http

        # Langfuse requires the project keys via Basic auth + the ingestion version header.
        headers:
          Authorization: "Basic ${AUTH_STRING}"
          x-langfuse-ingestion-version: "4"

        # Dev/demo: sample everything. Lower in production.
        randomSampling: true

        # Extra fields that Langfuse turns into rich prompt/completion + attribution.
        # These become the "Input" / "Output" you see on each Generation.
        fields:
          add:
            # Full conversation (Langfuse expects string, not base64)
            gen_ai.prompt: 'string(request.body)'
            gen_ai.completion: 'string(response.body)'

            # Request flags
            gen_ai.request.stream: 'json(request.body).stream'

            # Attribution (sent by test.sh and any well-behaved client)
            user.id: 'request.headers["x-user-id"]'
            session.id: 'request.headers["x-session-id"]'

            # Static tags useful for filtering in Langfuse
            environment: '"k8s-langfuse-demo"'
            client.ip: 'source.address'
EOF

echo ""
echo "==> AgentgatewayParameters updated with Langfuse tracing."
echo ""
echo "The AgentGateway controller should reconcile the change and update the"
echo "data-plane proxies. If traces still don't flow after a minute, force a"
echo "reload of the proxies that belong to the Gateway:"
echo ""
echo "  kubectl delete pods -n ${AGW_NAMESPACE} \\"
echo "    -l 'gateway.networking.k8s.io/gateway-name=agentgateway-proxy' --ignore-not-found"
echo ""
echo "Then send a test request:"
echo "  ./test.sh --users"
echo ""
echo "Finally, open Langfuse (port-forward 3000) and look under Traces / Generations."
echo "After you add pricing for the Qwen model you will see real cost numbers."
echo ""
echo "Done."
