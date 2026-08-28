# 17 — API-key-scoped token budgets on Kubernetes

Same v1.5.0 feature as [`16-api-key-scoped-token-budgets`](../16-api-key-scoped-token-budgets): budgets on the virtual API key (`llm.policies.apiKey.keys[].budgets`) plus `config.database`. That API is standalone-only in v1.5.0 (not an AgentgatewayPolicy CRD), so these manifests run `cr.agentgateway.dev/agentgateway:v1.5.0` in-cluster.

Keys in `k8s/01-config.yaml`:

| Bearer | Budget | On exceeded |
|--------|--------|-------------|
| `sk-demo-block` | 40 Tokens / 1h | `Block` (next call is 429 `budget_exceeded`) |
| `sk-demo-audit` | 40 Tokens / 1h | `Audit` (still 200; status shows `exceeded`) |
| `sk-demo-cost` | 0.00002 USD / 1h | `Block` (optional; needs the ConfigMap catalog) |

Charge happens **after** the LLM response. The call that crosses the limit still returns 200; the next `Block` call is denied. Windows are epoch-aligned (`1h` = the current UTC hour). Re-run the curls in the same hour and `sk-demo-block` is already over limit — delete the namespace (or the pod: `emptyDir` resets SQLite) to start a fresh window.

Keep `replicas: 1`. Do not add a `setup.sh` / `deploy.sh` / `run.sh`.

## 1. Prerequisites

- `kind` and `kubectl`
- A real `OPENAI_API_KEY` (the gateway calls `openai/gpt-4.1-nano`)

```sh
export OPENAI_API_KEY='sk-...'
# or: cp .env.example .env && edit .env && set -a && source .env && set +a
```

## 2. Kind cluster

Skip if you already have a cluster and `kubectl` talks to it.

```sh
kind create cluster --name agw-token-budgets
```

## 3. Namespace

```sh
kubectl apply -f k8s/00-namespace.yaml
```

## 4. Secret (not committed)

```sh
kubectl -n agw-token-budgets create secret generic openai \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY"
```

Re-create after a change: add `--dry-run=client -o yaml | kubectl apply -f -`.

## 5. Config, Deployment, Service

```sh
kubectl apply -f k8s/01-config.yaml
kubectl apply -f k8s/02-deployment.yaml
kubectl apply -f k8s/03-service.yaml
```

## 6. Wait until ready

```sh
kubectl -n agw-token-budgets wait --for=condition=available deploy/agentgateway --timeout=180s
kubectl -n agw-token-budgets get pods
```

If the pod is `CreateContainerConfigError`, the `openai` secret is missing. If it crash-loops, `kubectl -n agw-token-budgets logs deploy/agentgateway` — a `$` + uppercase token in a config comment is a common startup failure.

## 7. Port-forward

```sh
kubectl -n agw-token-budgets port-forward svc/agentgateway 4000:4000 15000:15000
```

Leave that running. LLM is `:4000`, admin UI / APIs are `:15000`.

## 8. Unauthenticated — expect 401

Strict `apiKey` mode. No Bearer token.

```sh
curl -sS -o /tmp/agw-noauth.json -w '%{http_code}\n' \
  http://127.0.0.1:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-4.1-nano","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
cat /tmp/agw-noauth.json
```

Expect **401** (any non-200 is the check).

## 9. Block key — first call 200

Usage is charged after the response, so the first call is allowed.

```sh
curl -sS http://127.0.0.1:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-demo-block' \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-4.1-nano","messages":[{"role":"user","content":"Explain token budgets in two short sentences."}],"max_tokens":32}'
```

Expect **200** and a `usage.total_tokens` field.

## 10. Status API

```sh
curl -sS 'http://127.0.0.1:15000/api/budgets/status?apiKeyName=demo-block'
```

`usage.used` should be greater than 0.

## 11. Block key — next call 429 `budget_exceeded`

40 Tokens is small; a second completion in the same hour usually trips it. If you still get 200, call again.

```sh
curl -sSD - http://127.0.0.1:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-demo-block' \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-4.1-nano","messages":[{"role":"user","content":"Explain token budgets in two short sentences."}],"max_tokens":32}'
```

Expect **429**, header `Retry-After`, and:

```json
{
  "error": {
    "message": "Budget exceeded",
    "type": "rate_limit_error",
    "code": "budget_exceeded"
  }
}
```

## 12. Audit key — still 200

Same 40-token limit, `onBudgetExceeded: Audit`.

```sh
curl -sS -o /tmp/agw-audit.json -w '%{http_code}\n' \
  http://127.0.0.1:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-demo-audit' \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-4.1-nano","messages":[{"role":"user","content":"Explain token budgets in two short sentences."}],"max_tokens":32}'
curl -sS 'http://127.0.0.1:15000/api/budgets/status?apiKeyName=demo-audit'
```

Expect **200**. Status still reports `used` / `remaining` / `exceeded`.

## 13. Optional — USD Block key

`sk-demo-cost` is 0.00002 USD / 1h on `gpt-4.1-nano` (0.10 USD / 1M input, 0.40 USD / 1M output from `model-catalog.json`). First call 200; the next is 429 once `used` crosses the limit.

```sh
curl -sS http://127.0.0.1:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-demo-cost' \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-4.1-nano","messages":[{"role":"user","content":"Explain token budgets in two short sentences."}],"max_tokens":32}'
curl -sS 'http://127.0.0.1:15000/api/budgets/status?apiKeyName=demo-cost'
```

If `usage.used` is `0`, the catalog did not price the model. Confirm the pod log contains `model catalog loaded`.

## 14. Optional — admin UI

Open <http://127.0.0.1:15000/ui/> → **LLM → Virtual API Keys** (Keys). Each key shows its budget meter. Same data as `GET /api/budgets/status`.

Saving in the UI writes `/api/config` and drops comments in the mounted file (the ConfigMap is the committed source; a UI save does not persist unless you copy the result back out).

## 15. Cleanup

```sh
kubectl delete namespace agw-token-budgets
```

If you created the Kind cluster only for this demo:

```sh
kind delete cluster --name agw-token-budgets
```
