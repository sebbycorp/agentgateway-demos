# 04 - Virtual Keys for LLM Access Control

This demo shows how to use **AgentGateway** to issue virtual API keys with per-key token budgets and cost tracking. It creates two users (Alice and Bob) with independent daily token budgets enforced through API key authentication and token-based rate limiting.

## How It Works

Virtual keys combine three AgentGateway capabilities into a unified access control system:

1. **API Key Authentication** — Each user gets a unique API key stored as a Kubernetes Secret. Requests without a valid key are rejected (401).
2. **Token-Based Rate Limiting** — Per-user daily token budgets enforced via an external rate limit server. When a user exhausts their budget, requests are rejected (429).
3. **Observability Metrics** — Per-key token usage and cost tracking via Prometheus metrics.

### Request Flow

```
Client Request
  │
  ├─ API Key Validation (401 if invalid)
  │
  ├─ Token Budget Check (429 if exhausted)
  │
  ├─ Route to LLM Provider
  │
  └─ Track token usage per user
```

> **Note:** Rate limiting is evaluated before prompt guards, so requests rejected by guardrails still consume quota. Authentication is evaluated before rate limiting, so unauthenticated requests do not consume quota.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [Helm](https://helm.sh/docs/intro/install/) installed
- OpenAI API key (`OPENAI_API_KEY` env var)

## Quick Start

```bash
# Set your API key
export OPENAI_API_KEY="your-openai-key"

# Deploy everything
./deploy.sh

# Run tests
./test.sh

# Cleanup
./cleanup.sh
```

## What Gets Deployed

### 1. Kind Cluster & AgentGateway

Creates a local Kubernetes cluster and installs AgentGateway with Gateway API support.

### 2. Gateway Listener

A Gateway resource listening on port 80 for HTTP traffic, accepting routes from all namespaces.

### 3. Provider API Key Secret

An Opaque secret storing the OpenAI API key for outbound LLM requests.

### 4. User API Key Secrets (Alice & Bob)

Two secrets of type `extauth.solo.io/apikey` — one for each user. These are the "virtual keys" that users include in their `Authorization: Bearer` header. Both are labeled `api-key-group: llm-users` for group-based selection.

### 5. API Key Authentication Policy

An `AgentgatewayPolicy` targeting the Gateway that enforces API key authentication in `Strict` mode. All requests must include a valid Bearer token.

### 6. Rate Limit Infrastructure

Redis and an Envoy rate limit server for enforcing per-user token budgets across gateway instances.

### 7. Per-Key Token Budget Policy

An `AgentgatewayPolicy` that enforces a daily token budget of 100,000 tokens per user, using CEL expressions to extract the user ID from the `X-User-ID` header.

### 8. OpenAI Backend & HTTPRoute

An `AgentgatewayBackend` pointing to OpenAI `gpt-5.4-mini`, with an HTTPRoute on `/openai`.

## Manual Step-by-Step

### Step 1: Create the Kind cluster

```bash
kind create cluster --name agw-series
```

### Step 2: Install Gateway API CRDs

```bash
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
```

### Step 3: Install AgentGateway

```bash
# CRDs
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace agentgateway-system \
  --version v1.1.0 \
  --set controller.image.pullPolicy=Always

# Control plane + data plane
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system \
  --version v1.1.0 \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait
```

### Step 4: Verify pods are running

```bash
kubectl get pods -n agentgateway-system
```

### Step 5: Create the Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
```

### Step 6: Create API key secrets

```bash
# Provider key (OpenAI)
kubectl create secret generic openai-secret \
  -n agentgateway-system \
  --from-literal=Authorization="$OPENAI_API_KEY"
```

```yaml
# User virtual keys
apiVersion: v1
kind: Secret
metadata:
  name: user-alice-key
  namespace: agentgateway-system
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
  namespace: agentgateway-system
  labels:
    api-key-group: llm-users
type: extauth.solo.io/apikey
stringData:
  api-key: sk-bob-xyz789uvw012
```

### Step 7: Create API key authentication policy

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: api-key-auth
  namespace: agentgateway-system
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
```

### Step 8: Deploy rate limit infrastructure

Deploy Redis and the Envoy rate limit server with a ConfigMap defining 100K tokens/day per user.

```yaml
# Redis
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: agentgateway-system
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
  namespace: agentgateway-system
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
---
# Rate limit config
apiVersion: v1
kind: ConfigMap
metadata:
  name: rate-limit-config
  namespace: agentgateway-system
data:
  config.yaml: |
    domain: token-budgets
    descriptors:
    - key: user_id
      rate_limit:
        unit: day
        requests_per_unit: 100000
---
# Rate limit server
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rate-limit-server
  namespace: agentgateway-system
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
  namespace: agentgateway-system
spec:
  selector:
    app: rate-limit-server
  ports:
  - port: 8081
    targetPort: 8081
    name: grpc
```

### Step 9: Create per-key token budget policy

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: daily-token-budget
  namespace: agentgateway-system
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
          namespace: agentgateway-system
          port: 8081
        descriptors:
        - entries:
          - name: user_id
            expression: 'request.headers["x-user-id"]'
          unit: Tokens
```

### Step 10: Create OpenAI backend

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai-backend
  namespace: agentgateway-system
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
```

### Step 11: Create HTTPRoute for /openai

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openai-route
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
        - name: openai-backend
          namespace: agentgateway-system
          group: agentgateway.dev
          kind: AgentgatewayBackend
```

### Step 12: Test

```bash
# Test with Alice's API key (should succeed)
curl -s "localhost:8080/openai" \
  -H "Authorization: Bearer sk-alice-abc123def456" \
  -H "X-User-ID: alice" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Say hello"}]}' | jq .

# Test with Bob's API key (should succeed)
curl -s "localhost:8080/openai" \
  -H "Authorization: Bearer sk-bob-xyz789uvw012" \
  -H "X-User-ID: bob" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Say hello"}]}' | jq .

# Test with invalid key (should get 401)
curl -sv "localhost:8080/openai" \
  -H "Authorization: Bearer sk-invalid-key" \
  -H "X-User-ID: mallory" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Say hello"}]}' 2>&1 | grep "< HTTP"

# Test without any key (should get 401)
curl -sv "localhost:8080/openai" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Say hello"}]}' 2>&1 | grep "< HTTP"
```

## Cleanup

```bash
# Remove all resources
kubectl delete AgentgatewayPolicy api-key-auth daily-token-budget -n agentgateway-system
kubectl delete AgentgatewayBackend openai-backend -n agentgateway-system
kubectl delete httproute openai-route -n agentgateway-system
kubectl delete deployment rate-limit-server redis -n agentgateway-system
kubectl delete service rate-limit-server redis -n agentgateway-system
kubectl delete configmap rate-limit-config -n agentgateway-system
kubectl delete secret openai-secret user-alice-key user-bob-key -n agentgateway-system

# Delete the cluster
kind delete cluster --name agw-series
```

## References

- [AgentGateway Virtual Keys Docs](https://agentgateway.dev/docs/kubernetes/latest/llm/virtual-keys/)
- [AgentGateway API Key Authentication](https://agentgateway.dev/docs/kubernetes/latest/llm/api-keys/)
- [AgentGateway Rate Limiting](https://agentgateway.dev/docs/kubernetes/latest/llm/rate-limiting/)
- [Gateway API HTTPRoute Spec](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.HTTPRoute)
