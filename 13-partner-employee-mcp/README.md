# Partner vs employee MCP

Same `/mcp` URL for everyone. Identity is `x-role`. Employees get the full catalog, full tool bodies, and Claude. Partners and consultants get a stripped catalog, a redacted tool body, and Grok.

## Why

Partners should not see the same MCP surface as employees. That is three different jobs — which tools exist, what a tool returns, and which model the app talks to — and none of them belong in the client.

This folder keeps one MCP URL (`http://localhost:3000/mcp`) and one public LLM name (`assistant`). The gateway reads `x-role: employee` | `partner` | `consultant` and applies three official policies:

- **Catalog** — `mcpAuthorization`. Rules are OR; unmatched tools are omitted from `tools/list`. Employees see every tool on the official everything server. Partner and consultant see `echo` only. No header → no rule matches → empty catalog.
- **Response** — `transformations.conditional` (first match wins, no fallback). Partner and consultant `tools/call` bodies are rewritten to a small redacted JSON-RPC payload. Employees skip the transform.
- **Pinned model** — `llm.virtualModels` + CEL `when` on the same `x-role` header (same pattern as `12-after-hours-kill-switch`). Clients always send `"model": "assistant"`. Employee → Anthropic `claude-sonnet-4-6`. Everyone else, including a missing header → xAI `grok-4.6`.

`ai.overrides` is not conditional. Do not fake that field; the pin is the virtual model.

Production identity is a JWT from [MCP authentication](https://agentgateway.dev/docs/standalone/latest/configuration/security/mcp-authn). This demo uses a header so the curls are copy-paste.

## What

This folder:

| File | Role |
|------|------|
| `config.yaml` | Standalone config. One MCP URL, one public virtual model, two internal LLM backends. |
| `.env.example` | `ANTHROPIC_API_KEY` and `XAI_API_KEY` placeholders. Copy to `.env` (gitignored). |
| `run.sh` | Loads `.env` and runs `agentgateway -f config.yaml` (`npx` required for the MCP target). |
| `demo.sh` | Catalog, echo call, and pinned model against a running gateway. |

**MCP URL** the client always calls: `http://localhost:3000/mcp`

**Identity header:** `x-role: employee` | `partner` | `consultant`

**LLM public name** the client always sends: `assistant`

**Backends** (internal; clients cannot request them directly):

- Employee → Anthropic `claude-sonnet-4-6`
- Partner / consultant / missing header → xAI `grok-4.6`

## How to set it up

1. **Install standalone agentgateway** (needs `npx` on PATH for `@modelcontextprotocol/server-everything`)

   ```sh
   curl -sL https://agentgateway.dev/install | bash
   agentgateway --version
   ```

2. **Put keys in `.env`** (never commit `.env`)

   ```sh
   cd 13-partner-employee-mcp
   cp .env.example .env
   # edit .env — set ANTHROPIC_API_KEY and XAI_API_KEY
   ```

   Or export them in your shell. Root `.gitignore` already ignores `.env`.

3. **Run the gateway from this folder**

   ```sh
   agentgateway -f config.yaml
   ```

   `./run.sh` does the same after sourcing `.env`. MCP is `http://localhost:3000/mcp`. LLM is `http://localhost:4000`. Admin UI is `http://localhost:15000/ui/`. If the playground warns about browser access, apply CORS — `x-role` is already on the allowed header list.

4. **Catalog** — same URL, different `x-role`

   ```sh
   # employee: full tools/list
   curl -s http://localhost:3000/mcp \
     -H "Content-Type: application/json" \
     -H "Accept: application/json, text/event-stream" \
     -H "mcp-protocol-version: 2025-06-18" \
     -H "x-role: employee" \
     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}'

   # then tools/list with the mcp-session-id the gateway returned, if any
   ```

   Repeat with `x-role: partner`. Partner should list `echo` only.

5. **Tool body** — `echo` as employee (full) vs partner (stripped)

   ```sh
   curl -s http://localhost:3000/mcp \
     -H "Content-Type: application/json" \
     -H "Accept: application/json, text/event-stream" \
     -H "mcp-protocol-version: 2025-06-18" \
     -H "x-role: partner" \
     -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello from partner"}}}'
   ```

   Partner / consultant `result` is the redacted payload from `transformations.conditional`. Employee `echo` returns the full everything-server body.

6. **Pinned model** — same `"model": "assistant"`

   ```sh
   curl -s http://localhost:4000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -H "x-role: employee" \
     -d '{
       "model": "assistant",
       "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
       "max_tokens": 16
     }' | jq '{model, content: .choices[0].message.content}'
   ```

   Repeat with `x-role: partner`. On a successful chat completion, read the **`model` field in the body**:

   - `claude-sonnet-4-6` — employee
   - `grok-4.6` — partner, consultant, or missing header

   Or run `./demo.sh` (needs the gateway already up). It handles the MCP initialize / session headers for you.
