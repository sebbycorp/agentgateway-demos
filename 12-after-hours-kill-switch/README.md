# After-hours setup

Standalone [agentgateway](https://agentgateway.dev) 1.4.x demo. Clients always send one public model name (`claude`). The gateway routes to **Anthropic Claude** during the day and **xAI Grok** after hours.

```
Client  ──POST /v1/chat/completions──►  agentgateway :4000
         model: claude
                                         ├─ daytime (8am–7pm America/Toronto) → Anthropic  claude-sonnet-4-6
                                         └─ after hours (7pm–8am local)       → xAI        grok-4.6
```

That is the whole use case. No OpenAI, no local Qwen, no `x-env` header.

## How routing works

One `llm.virtualModels` entry named `claude` uses `routing.conditional.targets` ([Virtual models](https://agentgateway.dev/docs/standalone/latest/llm/virtual-models/)). First matching `when` wins.

`timestamp(request.startTime).getHours()` is **UTC** ([CEL reference](https://agentgateway.dev/docs/standalone/latest/reference/cel/)). America/Toronto is **UTC-4** in August 2026 (EDT). After-hours is 7:00pm–8:00am local (19:00–08:00) = 23:00–12:00 UTC.

| Local (America/Toronto) | UTC hours (`getHours()`) | Upstream |
|-------------------------|--------------------------|----------|
| Daytime `08:00`–`18:59` | `12`–`22` | Anthropic `claude-sonnet-4-6` |
| After-hours `19:00`–`07:59` | `23`–`11` | xAI `grok-4.6` |

```cel
default(request.headers["x-force-after-hours"], "") != "true"
&& timestamp(request.startTime).getHours() >= 12
&& timestamp(request.startTime).getHours() < 23
```

If that is false, the fallback `when: "true"` sends the request to Grok.

`x-force-after-hours: true` is only a demo convenience so you can show the Grok path without waiting until night. It is not a second product.

## Prerequisites

- `curl` (and `jq` if you want pretty demo output)
- Two API keys (never commit them):

| Env var | Provider | Upstream model |
|---------|----------|----------------|
| `$ANTHROPIC_API_KEY` | [Anthropic](https://agentgateway.dev/docs/standalone/latest/llm/providers/anthropic/) | `claude-sonnet-4-6` |
| `$XAI_API_KEY` | [xAI](https://agentgateway.dev/docs/standalone/latest/llm/providers/xai/) | `grok-4.6` ([current xAI chat model](https://docs.x.ai/developers/models)) |

```sh
cp .env.example .env
# edit .env — .env is gitignored
```

## Install and run

```sh
curl -sL https://agentgateway.dev/install | bash

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

Look at the response `"model"` field: `claude-sonnet-4-6` (daytime) or `grok-4.6` (after hours).

## Curl examples

Both calls send `"model": "claude"`.

### 1. Daytime → Claude

```sh
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude",
    "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
    "max_tokens": 16
  }' | jq '{model, content: .choices[0].message.content}'
```

Expected during 12:00–22:59 UTC: `"model"` contains `claude-sonnet-4-6`. After hours this same curl goes to Grok.

### 2. After hours / force header → Grok

```sh
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-force-after-hours: true" \
  -d '{
    "model": "claude",
    "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
    "max_tokens": 16
  }' | jq '{model, content: .choices[0].message.content}'
```

Expected at any hour: `"model"` contains `grok-4.6`.

With the gateway already running:

```sh
./demo.sh
```

## References

- Standalone docs: https://agentgateway.dev/docs/standalone/latest/
- Virtual models: https://agentgateway.dev/docs/standalone/latest/llm/virtual-models/
- Anthropic: https://agentgateway.dev/docs/standalone/latest/llm/providers/anthropic/
- xAI: https://agentgateway.dev/docs/standalone/latest/llm/providers/xai/
- Config schema: https://agentgateway.dev/schema/config
