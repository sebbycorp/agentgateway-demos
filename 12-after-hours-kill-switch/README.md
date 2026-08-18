# After-hours cloud kill switch

Standalone [agentgateway](https://agentgateway.dev) 1.4.x demo. Clients hit **one** OpenAI-compatible URL and ask for GPT, Claude, or Grok by a short public name. The gateway keeps the requested **cloud** model only in daytime production; otherwise it rewrites every request to **xAI Grok**.

This demo does **not** use a local Qwen / Spark / `172.16.10.155` endpoint. The after-hours destination is xAI only.

```
Client  ──POST /v1/chat/completions──►  agentgateway :4000
                                         │
                                         ├─ daytime AND x-env: prod
                                         │    gpt-4o-mini     → OpenAI  gpt-4o-mini
                                         │    claude-sonnet   → Anthropic  claude-sonnet-4-6
                                         │    grok            → xAI  grok-4.6
                                         │
                                         └─ after-hours OR missing/non-prod x-env
                                              OR x-force-after-hours: true
                                              any public model → xAI  grok-4.6
```

## What it does

`llm.virtualModels` with `routing.conditional.targets` (see [Virtual models](https://agentgateway.dev/docs/standalone/latest/llm/virtual-models/)) evaluates CEL `when` expressions in order. First match wins.

Keep the requested cloud target only when **all** of these are true:

1. `request.headers["x-env"] == "prod"`
2. The request hour is daytime in **America/Toronto**
3. `x-force-after-hours` is not `true`

Otherwise the explicit fallback `when: "true"` sends the request to the internal xAI model.

Missing `x-env`, `x-env: workshop`, quiet hours, or `x-force-after-hours: true` all land on Grok.

### Time window (UTC)

`timestamp(request.startTime).getHours()` is **UTC** ([CEL reference](https://agentgateway.dev/docs/standalone/latest/reference/cel/)). America/Toronto is **UTC-4** in August 2026 (EDT).

| Local (America/Toronto) | UTC hours (`getHours()`) | If `x-env: prod` |
|-------------------------|--------------------------|------------------|
| Daytime `08:00`–`18:59` | `12`–`22` | Keep GPT / Claude / Grok as requested |
| After-hours `19:00`–`07:59` | `23`–`11` | Rewrite to xAI `grok-4.6` |

CEL used on each virtual model:

```cel
default(request.headers["x-env"], "") == "prod"
&& default(request.headers["x-force-after-hours"], "") != "true"
&& timestamp(request.startTime).getHours() >= 12
&& timestamp(request.startTime).getHours() < 23
```

`x-force-after-hours: true` lets you demonstrate the Grok rewrite at any hour.

## Public model names

| Client sends (`"model"`) | Daytime + `x-env: prod` | Otherwise |
|--------------------------|-------------------------|-----------|
| `gpt-4o-mini` | OpenAI **`gpt-4o-mini`** | xAI **`grok-4.6`** |
| `claude-sonnet` | Anthropic **`claude-sonnet-4-6`** | xAI **`grok-4.6`** |
| `grok` | xAI **`grok-4.6`** | xAI **`grok-4.6`** |

Concrete upstreams are `visibility: internal` so clients cannot skip the kill switch by naming them directly.

## Prerequisites

- `curl` (and `jq` if you want pretty demo output)
- API keys in the environment (never commit them):

| Env var | Provider | Upstream model |
|---------|----------|----------------|
| `$OPENAI_API_KEY` | [OpenAI](https://agentgateway.dev/docs/standalone/latest/llm/providers/openai/) | `gpt-4o-mini` |
| `$ANTHROPIC_API_KEY` | [Anthropic](https://agentgateway.dev/docs/standalone/latest/llm/providers/anthropic/) | `claude-sonnet-4-6` |
| `$XAI_API_KEY` | [xAI](https://agentgateway.dev/docs/standalone/latest/llm/providers/xai/) | `grok-4.6` ([current xAI chat model](https://docs.x.ai/developers/models); agentgateway's example still shows `grok-2-latest`, which xAI has retired) |

```sh
cp .env.example .env
# edit .env — .env is gitignored
```

Or export the three variables in your shell.

## Install the binary

```sh
curl -sL https://agentgateway.dev/install | bash
agentgateway --version
```

This demo targets standalone **1.4.x** (`llm.virtualModels`, `llm.providers`, named `gateways`).

## Run

```sh
export OPENAI_API_KEY='...'
export ANTHROPIC_API_KEY='...'
export XAI_API_KEY='...'

agentgateway -f config.yaml
```

Or, after filling `.env`:

```sh
./run.sh
```

| URL | What it is |
|-----|------------|
| `http://localhost:4000/v1/chat/completions` | OpenAI-compatible LLM endpoint |
| `http://localhost:15000/ui/` | Admin UI |

Check the CEL playground in the admin UI if a `when` expression does not behave as you expect.

## Curl examples

All five calls use the same URL. Look at the response `"model"` field to see where the kill switch sent the request (`gpt-4o-mini`, `claude-sonnet-4-6`, or `grok-4.6`).

**Cases 1–3 only keep the requested cloud model during 12:00–22:59 UTC.** Outside that window they also rewrite to Grok — that is the kill switch. Use case 5 to force Grok at any hour.

### 1. `x-env: prod` daytime → GPT

```sh
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-env: prod" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
    "max_tokens": 16
  }' | jq '{model, content: .choices[0].message.content}'
```

Expected in daytime: `"model"` contains `gpt-4o-mini`.

### 2. `x-env: prod` daytime → Claude

```sh
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-env: prod" \
  -d '{
    "model": "claude-sonnet",
    "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
    "max_tokens": 16
  }' | jq '{model, content: .choices[0].message.content}'
```

Expected in daytime: `"model"` contains `claude-sonnet-4-6`.

### 3. `x-env: prod` daytime → Grok

```sh
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-env: prod" \
  -d '{
    "model": "grok",
    "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
    "max_tokens": 16
  }' | jq '{model, content: .choices[0].message.content}'
```

Expected: `"model"` contains `grok-4.6` (Grok is already the xAI cloud model).

### 4. Missing `x-env` or `x-env: workshop` → Grok

```sh
# missing x-env
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
    "max_tokens": 16
  }' | jq '{model, content: .choices[0].message.content}'

# non-prod workshop header
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-env: workshop" \
  -d '{
    "model": "claude-sonnet",
    "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
    "max_tokens": 16
  }' | jq '{model, content: .choices[0].message.content}'
```

Expected: both rewrite to `grok-4.6`.

### 5. `x-force-after-hours: true` → Grok

```sh
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-env: prod" \
  -H "x-force-after-hours: true" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
    "max_tokens": 16
  }' | jq '{model, content: .choices[0].message.content}'
```

Expected at any hour: `grok-4.6`.

### Run all five

With the gateway already running:

```sh
./demo.sh
```

## Config notes

- Simplified `llm:` mode ([configuration modes](https://agentgateway.dev/docs/standalone/latest/llm/configuration-modes/)), same style as `00-standalone-latest`.
- Named `gateways.llm` on port **4000** (default LLM listener when no gateway is declared).
- Reusable `llm.providers[]` + `provider.reference` ([multiple providers](https://agentgateway.dev/docs/standalone/latest/llm/providers/multiple-llms/)).
- API keys are `$VAR` references only. Root `.gitignore` already ignores `.env` / `*.env`.

## References

- Standalone docs: https://agentgateway.dev/docs/standalone/latest/
- Virtual models: https://agentgateway.dev/docs/standalone/latest/llm/virtual-models/
- xAI provider: https://agentgateway.dev/docs/standalone/latest/llm/providers/xai/
- Config schema: https://agentgateway.dev/schema/config
