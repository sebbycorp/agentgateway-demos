# 18 — Block curl with CEL HTTP authorization (standalone v1.5.0)

A CEL `deny` rule on the standalone LLM listener. Default `curl` is blocked because its User-Agent contains `curl`. A browser-like User-Agent is allowed through to OpenAI.

This folder is **standalone Docker**. The Kubernetes snippet at the bottom is only an appendix — it uses a different schema.

Docs: [HTTP authorization](https://agentgateway.dev/docs/standalone/latest/configuration/security/http-authz)

## 1. Prerequisites

- Docker
- A real `OPENAI_API_KEY` (needed for the allow-path curls in steps 4–5)

```sh
cd 18-standalone-cel-block-curl
cp .env.example .env
# put your key in .env, then:
set -a && source .env && set +a
```

Or just `export OPENAI_API_KEY='sk-...'`.

## 2. Start the gateway

Bind-mount the committed `config.yaml` and pass the key in as an env var. The gateway expands `$OPENAI_API_KEY` itself — do not paste the secret into the file.

```sh
docker run -d --name agw-cel-block-curl \
  -p 127.0.0.1:4000:4000 -p 127.0.0.1:15000:15000 \
  -e OPENAI_API_KEY \
  -v "$PWD/config.yaml:/config.yaml:ro" \
  cr.agentgateway.dev/agentgateway:v1.5.0 \
  -f /config.yaml
```

Same thing: `./run.sh`.

Wait until the admin port answers, then open <http://localhost:15000/ui/>.

```sh
curl -sf --max-time 2 http://127.0.0.1:15000/ >/dev/null && echo ready
```

If the container exits immediately, `docker logs agw-cel-block-curl` — a missing `OPENAI_API_KEY` is the usual cause (`environment variable not found`).

> Some Docker setups cannot see a host bind mount. Copy the file into a named volume instead, then point `-f` at that path. Do **not** use this as the normal path.
>
> ```sh
> docker volume create agw-cel-block-curl-config
> docker run --rm -v agw-cel-block-curl-config:/cfg -v "$PWD":/src alpine \
>   cp /src/config.yaml /cfg/config.yaml
> docker run -d --name agw-cel-block-curl \
>   -p 127.0.0.1:4000:4000 -p 127.0.0.1:15000:15000 \
>   -e OPENAI_API_KEY \
>   -v agw-cel-block-curl-config:/cfg \
>   cr.agentgateway.dev/agentgateway:v1.5.0 \
>   -f /cfg/config.yaml
> ```

## 3. Block default curl — expect 403

Default `curl` sends a User-Agent like `curl/8.5.0`. The deny rule matches.

```sh
curl -sS -w '\nHTTP %{http_code}\n' http://127.0.0.1:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-4.1-nano","messages":[{"role":"user","content":"Say hi."}],"max_tokens":16}'
```

Expected: HTTP **403**, body `authorization failed`.

## 4. Allow a non-curl User-Agent — expect 200

```sh
curl -sS -A 'Mozilla/5.0' -w '\nHTTP %{http_code}\n' \
  http://127.0.0.1:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-4.1-nano","messages":[{"role":"user","content":"Say hi."}],"max_tokens":16}'
```

Expected: HTTP **200** from OpenAI (`choices[0].message.content` present).

## 5. Same allow with Python urllib

Python's default User-Agent is `Python-urllib/3.x` — no `curl` substring.

```sh
python3 - <<'PY'
import json, urllib.request
req = urllib.request.Request(
    "http://127.0.0.1:4000/v1/chat/completions",
    data=json.dumps({
        "model": "openai/gpt-4.1-nano",
        "messages": [{"role": "user", "content": "Say hi."}],
        "max_tokens": 16,
    }).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req) as resp:
    print("HTTP", resp.status)
    print(resp.read().decode())
PY
```

Expected: HTTP **200**.

## 6. Stop

```sh
docker rm -f agw-cel-block-curl
```

Same thing: `./cleanup.sh`.

## What the config does

The working rule is standalone `llm.policies.authorization.rules`:

```yaml
policies:
  authorization:
    rules:
    - deny: 'request.headers["user-agent"].contains("curl")'
```

Verified on standalone **v1.5.0**:

| Client | User-Agent | Result |
|--------|------------|--------|
| default `curl` | `curl/…` | HTTP 403, `authorization failed` |
| `curl -A 'Mozilla/5.0'` | `Mozilla/5.0` | HTTP 200 from OpenAI |
| Python `urllib` | `Python-urllib/3.x` | HTTP 200 |

A CEL expression that cannot be evaluated is treated as `false`. A failed `deny` does **not** block the request (fail-open). See the [HTTP authorization docs](https://agentgateway.dev/docs/standalone/latest/configuration/security/http-authz).

## Appendix: same idea on Kubernetes (not this demo)

Kubernetes uses `AgentgatewayPolicy` with a different official schema. Do **not** paste the standalone `rules: - deny:` form into a CRD.

```yaml
authorization:
  action: Deny
  policy:
    matchExpressions:
      - 'request.headers["user-agent"].contains("curl")'
```

This folder does not include Kind or manifests.

## Files

| File | Role |
|------|------|
| `config.yaml` | Exact standalone v1.5.0 config (the `rules: - deny:` form) |
| `run.sh` | Tiny `docker run` with a bind-mounted config |
| `test.sh` | The three checks from steps 3–5 |
| `cleanup.sh` | `docker rm -f` |
| `.env.example` | `OPENAI_API_KEY=` |

## References

- HTTP authorization: <https://agentgateway.dev/docs/standalone/latest/configuration/security/http-authz>
- Standalone schema: <https://agentgateway.dev/schema/config>
- Image: `cr.agentgateway.dev/agentgateway:v1.5.0`
