# Phase 1 — Stand up agentgateway and get full visibility *first*

This is the "start here" runbook for the workshop. Goal: install agentgateway, turn on **every** log/metric/trace stream **before** you route real traffic, then push a single request through and confirm you can see it everywhere. Once visibility is proven, governance, budgets, and A/B testing (the later modules) all have something to measure.

> **Versions & editions.** Commands below target **Solo Enterprise for agentgateway**, current release **2026.6.0** (the install page pins a `v2026.x.0` version — set it to the current one). The Enterprise control plane needs a **license key**; open-source agentgateway is free and can run standalone with a local config file if you don't want the K8s control plane. Resource shapes differ across editions/versions (e.g. OSS examples use `gatewayClassName: agentgateway` and `spec.llm.provider...`, while current Enterprise docs use `gatewayClassName: enterprise-agentgateway` and `spec.ai.provider...`). Always reconcile YAML against the docs for *your* installed version.

---

## 0. What "done" looks like

By the end of Phase 1 you can answer "what just happened to that request?" from five angles:

1. **Pod logs** — control plane + proxy (`kubectl logs`)
2. **agctl** — live proxy logs, per-request traces, and a dump of the running config
3. **Metrics** — control-plane and proxy metrics scraped by Prometheus
4. **Tracing** — spans exported to an OTel collector
5. **The response itself** — the LLM `usage` block (prompt/completion/total tokens) = your first cost signal

---

## 1. Prerequisites

- A Kubernetes cluster, `kubectl`, and `helm`. For local/workshop use, Kind is fine:
  ```sh
  kind create cluster
  ```
- A Solo Enterprise for agentgateway **license key** (contact your Solo rep if you don't have one).

```sh
export AGENTGATEWAY_LICENSE_KEY=<your-license-key>
export AGW_VERSION=v2026.6.0   # set to the current release
```

---

## 2. Install the control plane

```sh
# 1) Kubernetes Gateway API CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

# 2) agentgateway CRDs
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace --namespace agentgateway-system \
  --version ${AGW_VERSION}

# 3) agentgateway control plane
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n agentgateway-system \
  --version ${AGW_VERSION} \
  --set-string licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY}

# 4) confirm the control plane is running
kubectl get pods -n agentgateway-system
```

> The **data plane** pods (`agentgateway-proxy`, `ext-auth-service`, `rate-limiter`, `ext-cache`) are created only **after** you deploy a Gateway in the next step.

---

## 3. Create the proxy (this spins up the data plane)

```sh
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
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
```

Verify and grab the address:

```sh
kubectl get gateway agentgateway-proxy -n agentgateway-system
kubectl get deployment agentgateway-proxy -n agentgateway-system
kubectl get svc agentgateway-proxy -n agentgateway-system

# Local/dev (Kind): port-forward
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &
export GW=localhost:8080

# Cloud LoadBalancer instead:
# export GW=$(kubectl get svc -n agentgateway-system agentgateway-proxy -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}")
```

---

## 4. ★ Turn on visibility BEFORE sending traffic

This is the heart of Phase 1. Get all of these tailing/scraping first, so the smoke test in Step 5 lights them up.

### 4a. Pod logs (always available, zero setup)

```sh
# control plane
kubectl logs -n agentgateway-system deploy/enterprise-agentgateway -f

# the proxy / data plane (container is the agent-gateway)
kubectl logs -n agentgateway-system deploy/agentgateway-proxy -f
```

### 4b. agctl — the operator CLI for logs, traces, and config

`agctl` is the fastest way to see what the proxy is actually doing. Install it per the docs (Operations → Install agctl), then:

```sh
agctl version

# live proxy logs (richer than kubectl logs)
agctl proxy log

# control-plane logs
agctl controller log

# dump the running proxy config — confirm your routes/backends are programmed
agctl proxy config all
agctl proxy config backends

# trace a single request end-to-end through the proxy
agctl proxy trace
```

Keep `agctl proxy log` running in one pane and `agctl proxy trace` ready in another — you'll use both in Step 5. (See also Operations → **Debug your setup** and **Inspect agentgateway configuration**.)

### 4c. Metrics (Prometheus)

agentgateway exposes Prometheus metrics for both the control plane and the proxy. Point your Prometheus at them (or port-forward to eyeball raw metrics). The proxy commonly exposes its metrics/admin on port `15020` — confirm for your version:

```sh
POD=$(kubectl get pod -n agentgateway-system \
  -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy \
  -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n agentgateway-system pod/$POD 15020:15020 &
curl -s localhost:15020/metrics | head
```

See Observability → **Control plane metrics**, and LLM → **Metrics and logs** for the token/cost metrics specifically.

### 4d. Tracing (OpenTelemetry)

Deploy/enable the OTel stack and configure the gateway to export spans, so each request becomes a trace carrying model, tokens, latency, route, and policy actions. Start from Observability → **OTel stack** and **Tracing**. Minimal Helm-style toggle:

```yaml
# values-tracing.yaml (reconcile keys with your version's Helm reference)
gateway:
  envs:
    OTEL_EXPORTER_OTLP_ENDPOINT: "http://<your-otel-collector>:4317"
    OTEL_EXPORTER_OTLP_PROTOCOL: "grpc"
```
```sh
helm upgrade enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n agentgateway-system --version ${AGW_VERSION} \
  --reuse-values -f values-tracing.yaml
```

For richer storage of traces, see Observability → **ClickHouse data store**, and the **Solo UI** for a visual view of traffic.

### 4e. Access logging (structured, with custom fields)

Enable access logging and add CEL variables (e.g. model, request id, team) so logs are queryable from day one. See Security → **Access logging** and Traffic management → **Log CEL variables in access logs**.

---

## 5. Smoke test: one request, seen everywhere

You need real traffic to validate the visibility plane. Add a minimal LLM route. (No provider key? Use the **httpbun** mock-LLM guide instead — it speaks the OpenAI chat-completions API.)

```sh
# 1) provider key as a secret
export OPENAI_API_KEY='<your-key>'
kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: agentgateway-system
type: Opaque
stringData:
  Authorization: $OPENAI_API_KEY
EOF

# 2) LLM backend
kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai:
        model: gpt-3.5-turbo
  policies:
    auth:
      secretRef:
        name: openai-secret
EOF

# 3) route to it
kubectl apply -f- <<EOF
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
    - backendRefs:
      - name: openai
        namespace: agentgateway-system
        group: agentgateway.dev
        kind: AgentgatewayBackend
EOF
```

Now send a request and watch your panes:

```sh
curl "$GW/v1/chat/completions" -H content-type:application/json -d '{
  "model": "",
  "messages": [
    {"role":"user","content":"Compose a short poem about recursion."}
  ]
}' | jq
```

**Confirm the request appears in all five places:**

- `agctl proxy log` shows the request hit the route and backend.
- `agctl proxy trace` shows a span with latency + route.
- the metrics endpoint increments request/token counters.
- the OTel collector (and/or Solo UI) shows the trace.
- the JSON response includes a `usage` block — e.g. `prompt_tokens`, `completion_tokens`, `total_tokens`. **That token block is your first cost signal** and the seed for budgets and A/B comparisons later.

For Claude specifically, swap the backend to the Anthropic provider (LLM → Providers → Anthropic) and point Claude Code at the route with `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`.

---

## 6. Phase 1 validation checklist

- [ ] Control plane pod `Running`; data plane pods present after Gateway apply.
- [ ] Gateway has an address (or port-forward works); `agctl proxy config all` shows the route + backend programmed.
- [ ] `kubectl logs` and `agctl proxy log` both tail cleanly.
- [ ] Metrics endpoint returns data; Prometheus is scraping it.
- [ ] A trace appears in the OTel collector / Solo UI for a test request.
- [ ] A smoke-test request returns a `usage` token block.

When every box is checked, you have the measurement plane the rest of the workshop builds on — proceed to governance (identity, rate limits, prompt guards), then dollar budgets, then A/B testing.

---

## 7. Quick troubleshooting

- **No data plane pods?** They appear only after a Gateway referencing the `enterprise-agentgateway` class exists.
- **Gateway address stuck `<pending>`?** Expected on Kind/minikube — use the port-forward path.
- **Route not taking effect?** `agctl proxy config all` / `agctl proxy config backends` to confirm it was programmed; check the HTTPRoute `parentRefs` name/namespace match the Gateway.
- **Connection refused from the client?** Verify `$GW`, the port-forward, and that the request path matches your route (`/v1/chat/completions` vs a custom `/openai` prefix).

---

## 8. Canonical docs used

- Get started / install: https://docs.solo.io/agentgateway/latest/quickstart/install/
- LLM (OpenAI) quickstart: https://docs.solo.io/agentgateway/latest/quickstart/llm/  (httpbun mock: https://docs.solo.io/agentgateway/latest/llm/providers/httpbun/)
- Anthropic provider: https://docs.solo.io/agentgateway/latest/llm/providers/anthropic/
- Operations — Install agctl: https://docs.solo.io/agentgateway/latest/operations/agctl/ · Debug: …/operations/debug/ · Trace requests: …/operations/trace-requests/ · Inspect config: …/operations/inspect-config/
- Observability — OTel stack: https://docs.solo.io/agentgateway/latest/observability/otel-stack/ · Control-plane metrics: …/observability/control-plane-metrics/ · Tracing: …/observability/tracing/ · ClickHouse: …/observability/clickhouse/ · Solo UI: …/observability/ui/
- LLM metrics & logs (tokens/cost): https://docs.solo.io/agentgateway/latest/llm/observability/
- Access logging: https://docs.solo.io/agentgateway/latest/security/access-logging/ · CEL log vars: https://docs.solo.io/agentgateway/latest/traffic-management/transformations/access-logs/
- agctl CLI reference: https://docs.solo.io/agentgateway/latest/reference/agctl/

