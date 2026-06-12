# 09 - Kubernetes + Langfuse Cost Analysis (Local Model)

**Everything inside a single kind cluster**: AgentGateway (as Kubernetes Gateway) + full self-hosted Langfuse (Helm) + routing to your local LLM.

This demo shows **cost analysis** of LLM usage by:

- Routing requests through AgentGateway to a local OpenAI-compatible model (`Qwen/Qwen3.6-35B-A3B-FP8` running at `172.16.10.173:8000`)
- AgentGateway emitting rich GenAI OpenTelemetry traces (model, input/output tokens, latency, prompt/completion bodies, user/session attribution)
- Langfuse ingesting those traces directly over OTLP/HTTP as "generations"
- Configuring per-model pricing inside Langfuse → automatic USD cost tracking, dashboards, and spend analysis

No external SaaS LLM keys. No external Langfuse. 100% reproducible in kind.

## Architecture

```
Client (curl / SDK)
      │
      ▼  /v1/chat/completions   (port-forward localhost:8080)
┌─────────────────────┐
│  AgentGateway       │  (Gateway + HTTPRoute "spark-route" + AgentgatewayBackend "spark")
│  (in kind)          │───hostOverride──▶ 172.16.10.173:8000  (your local vLLM / text-generation-inference / etc.)
│                     │
│  + OTLP traces      │
└─────────┬───────────┘
          │ http://langfuse-web.langfuse.svc:3000/api/public/otel/v1/traces
          │   (Basic auth with project pk:sk)
          ▼
┌─────────────────────┐
│  Langfuse (Helm)    │  (web + worker + postgres + clickhouse + redis + blob)
│  inside the cluster │
└─────────────────────┘
          │
          ▼ UI (port-forward 3000)
   Traces • Generations • Token usage • Costs (after you set model pricing)
```

## Prerequisites

- `kind`, `kubectl`, `helm`, `jq`
- Docker (for kind)
- **On macOS**: Docker Desktop should have **at least 8-10 GB RAM + 4 CPUs** allocated (ClickHouse is memory hungry)
- Your local model server already running and reachable from containers on `172.16.10.173:8000` (the value you provided for the spark backend)

**Important**: Langfuse self-hosted is the slowest part of the demo. First-time bootstrap (ClickHouse + Postgres schema + migrations) commonly takes **5-15 minutes** inside kind. The `deploy.sh` uses kind-optimized values (`langfuse-kind-values.yaml`) to keep resource usage reasonable.

## Quick Start

```bash
# 1. Deploy the whole stack (kind + Langfuse + AgentGateway + spark route)
./deploy.sh
# NOTE: Be patient — the script will print progress. Langfuse (especially ClickHouse)
#       can take 5-15 minutes on first run. You can watch in another terminal:
#       kubectl get pods -n langfuse -w

# 2. Once the langfuse-web pod is 1/1 Running, set up a project + get keys
kubectl port-forward -n langfuse svc/langfuse-web 3000:3000 &
# Open http://localhost:3000
#   - Create account / org / project (e.g. "cost-analysis")
#   - Settings → API Keys → copy Public Key (pk-lf-...) and Secret Key (sk-lf-...)

# 3. Wire AgentGateway tracing → Langfuse (injects real auth + OTLP endpoint)
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
./configure-observability.sh

# 4. Port-forward the gateway
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80 &

# 5. Fire traffic (re-uses the same test patterns as the standalone Langfuse demo)
./test.sh --users
# or
./test.sh "Write a haiku about Kubernetes gateways."

# 6. (Optional but required for real $ costs) Configure model pricing in Langfuse
#    Project → Settings → Models → Add "Qwen/Qwen3.6-35B-A3B-FP8"
#    Typical example prices (adjust to your actual):
#      Input:  0.20 per 1M tokens
#      Output: 0.60 per 1M tokens
```

Then open Langfuse at http://localhost:3000 and explore:

- Traces (with user.id / session.id you passed in headers)
- Generations (one per LLM call, with prompt, completion, model, tokens)
- Usage & Cost dashboards (once pricing is set)

## What Gets Deployed

| Component              | How                                      | Notes |
|------------------------|------------------------------------------|-------|
| kind cluster           | `kind create cluster`                    | Named `agw-k8s-langfuse` |
| Gateway API CRDs       | Official v1.5.0 manifest                 | Required by AgentGateway |
| Langfuse (self-hosted) | `helm install langfuse/langfuse` + `langfuse-kind-values.yaml` | Full stack tuned for kind (1 replica, lower resources). Expect 5-15 min first boot. |
| AgentGateway CRDs + controller | Official OCI Helm charts (v1.1.0) | `agentgateway-system` ns |
| AgentgatewayParameters | Custom resource (rawConfig)              | Carries the tracing section (updated by configure script) |
| Gateway                | `agentgateway-proxy` (HTTP 80)           | Standard Gateway API |
| AgentgatewayBackend    | `spark`                                  | Local model, host+port, no auth, no TLS (plain http) |
| HTTPRoute              | `spark-route` (prefix `/v1`)             | OpenAI-compatible path support |
| Tracing                | Direct OTLP/HTTP from proxy → Langfuse   | No sidecar collector needed (same pattern as the 08 standalone MVP) |

## Local Model Configuration (exactly as requested)

```yaml
# Equivalent of your provided snippet, expressed as the Kubernetes CR
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: spark
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai:
        model: "Qwen/Qwen3.6-35B-A3B-FP8"
      host: "172.16.10.173"
      port: 8000
```

The HTTPRoute named `spark-route` sends traffic reaching `/v1/...` to this backend.

## Observability / Cost Path (no collector)

AgentGateway natively emits GenAI semantic conventions over OpenTelemetry:

- `gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`
- Full prompt / completion bodies (via extra fields)
- `user.id`, `session.id` (passed as `x-user-id` / `x-session-id` headers – captured in the Parameters)

Langfuse's built-in OTLP receiver (`/api/public/otel/v1/traces`) understands these attributes and turns them into first-class "Generations" with token accounting.

Because we use `otlpProtocol: http` and send straight to the Langfuse web service inside the cluster, we need **zero** extra OpenTelemetry collector for the MVP.

## Updating Tracing / Keys (configure-observability.sh)

Langfuse project keys are created in the UI after first signup. The configure script:

1. Base64-encodes `pk:sk`
2. Applies an `AgentgatewayParameters` resource containing the full tracing block pointing at the in-cluster Langfuse service + the real Authorization header
3. The AgentGateway controller picks up the change and reconfigures the data-plane proxies.

You only need to run it once per project (or re-run if you rotate keys).

## Test Script

`./test.sh` is intentionally compatible with the patterns from the standalone Langfuse demo (08). It supports:

- Default single request
- Custom prompt: `./test.sh "your question"`
- Many demo users with different token budgets + attribution headers: `./test.sh --users`
- Streaming: `./test.sh --stream`
- Listing models: `./test.sh --models`

All requests include the attribution headers so you can filter beautifully in Langfuse.

## Cleanup

```bash
./cleanup.sh
```

This removes the CRs, Helm releases, namespaces, and the kind cluster.

## Tips & Troubleshooting

- **Langfuse pods stuck / CrashLoop**: Common on first boot while ClickHouse/Postgres initialize. Just wait (the script has generous timeouts). `kubectl get pods -n langfuse` and look at logs of `langfuse-web` / `langfuse-worker`.
- **Model not reachable**: From inside kind, try `kubectl run -it --rm debug --image=curlimages/curl -- curl -v http://172.16.10.173:8000/v1/models`. If it fails, adjust the IP in the AgentgatewayBackend or expose your model server differently.
- **Traces not appearing**: After `./configure-observability.sh`, delete the current proxy pods so they pick the new config:
  `kubectl delete pods -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy`
  Then re-send a request.
- **Costs are zero / missing**: You must explicitly add the model name + prices in Langfuse (Project → Settings → Models). Langfuse does not guess prices.
- **Want the full OTel + Grafana stack too?** You can layer the official agentgateway OTel + kube-prometheus-stack manifests on top later; this demo deliberately stays minimal (direct to Langfuse) for cost analysis.

### Langfuse-Specific Notes & Troubleshooting

Langfuse is the slowest and most resource-heavy component. The `deploy.sh` now:
- Uses `langfuse-kind-values.yaml` (1 replica everywhere + reduced memory/CPU requests)
- Does phased waits (databases first, then web/worker)
- Uses longer timeouts (up to 20 min for Helm + per-component waits)

**If after `./deploy.sh` the web pod is not yet 1/1 Running**:
```bash
kubectl get pods -n langfuse -w
# or
kubectl logs -n langfuse -l app.kubernetes.io/component=web --tail=50
```

Common on first run:
- ClickHouse taking a long time to initialize (watch for "ClickHouse server is ready")
- PostgreSQL migrations

You can safely re-run `./deploy.sh` — it is idempotent for most steps (Helm upgrade, kubectl apply).

If you are very resource-constrained, you can manually edit `langfuse-kind-values.yaml` before running the script (lower memory further or disable persistence for a pure ephemeral demo).

## References

- AgentGateway Kubernetes docs: https://agentgateway.dev/docs/kubernetes/latest
- Langfuse self-hosting (Helm): https://langfuse.com/self-hosting/deployment/kubernetes-helm
- Langfuse OTLP ingest: https://langfuse.com/docs/opentelemetry
- Previous standalone Langfuse + agentgateway demo: `../08-standalone-langfuse/`

Enjoy watching your local Qwen spend add up in Langfuse!
