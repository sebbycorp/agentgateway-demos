# After-hours Claude → Grok

Daytime quality on Claude. After-hours spend on Grok. Same URL, same `"model": "claude"`. The switch is a CEL virtual-model policy in standalone agentgateway — not an if/else in your app.

## Why

During the workday you want Claude. That is the default quality path.

After 7pm America/Toronto you do not want that bill. The gateway silently rewrites every request to xAI Grok until 8am. Clients keep calling one OpenAI-compatible URL. No SDK change, no cron, no client-side hour check.

This lives in `config.yaml` as `llm.virtualModels` + a CEL `when`. Agentgateway evaluates `timestamp(request.startTime).getHours()` on each request and picks the backend. Your app always sends `claude`.

## What

This folder:

| File | Role |
|------|------|
| `config.yaml` | Standalone 1.4.x config. One public virtual model, two internal backends. |
| `.env.example` | `ANTHROPIC_API_KEY` and `XAI_API_KEY` placeholders. Copy to `.env` (gitignored). |
| `run.sh` | Loads `.env` and runs `agentgateway -f config.yaml`. |
| `demo.sh` | Two curls against a running gateway (daytime vs force header). |

**Public name** the client always sends: `claude`

**Backends** (internal; clients cannot request them directly):

- Daytime → Anthropic `claude-sonnet-4-6`
- After hours → xAI `grok-4.6`

**Window.** After-hours is 7:00pm–8:00am America/Toronto. CEL `getHours()` is UTC, and Toronto is UTC-4 in August (EDT), so the YAML uses **12–22 UTC for daytime** (`>= 12 && < 23`). Hours `23`–`11` UTC are Grok.

**Optional demo header.** `x-force-after-hours: true` sends that request to Grok even at noon. It is only so you can show the night path without waiting until 7pm.

## How to set it up

1. **Install standalone agentgateway**

   ```sh
   curl -sL https://agentgateway.dev/install | bash
   agentgateway --version
   ```

2. **Put keys in `.env`** (never commit `.env`)

   ```sh
   cd 12-after-hours-kill-switch
   cp .env.example .env
   # edit .env — set ANTHROPIC_API_KEY and XAI_API_KEY
   ```

   Or export them in your shell. Root `.gitignore` already ignores `.env`.

3. **Run the gateway from this folder**

   ```sh
   agentgateway -f config.yaml
   ```

   `./run.sh` does the same after sourcing `.env`. LLM is `http://localhost:4000`. Admin UI is `http://localhost:15000/ui/`.

4. **Daytime path (Claude)** — same public model every time

   ```sh
   curl -s http://localhost:4000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{
       "model": "claude",
       "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
       "max_tokens": 16
     }' | jq '{model, content: .choices[0].message.content}'
   ```

   Between 12:00 and 22:59 UTC this should hit Anthropic. After 7pm Toronto this same curl is Grok — that is the point.

5. **Force Grok without waiting until night**

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

   Or run `./demo.sh` (needs the gateway already up).

6. **Confirm who served it**

   On a successful chat completion, agentgateway returns OpenAI-compatible JSON. Read the **`model` field in the body**:

   - `claude-sonnet-4-6` — Anthropic
   - `grok-4.6` — xAI

   The process log for that request also prints `gen_ai.provider.name` (`anthropic` or `xai`) and `gen_ai.request.model`. There is no extra provider header on the response.
