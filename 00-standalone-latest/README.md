# AgentGateway standalone — cost & tokenomics dashboard demo

Run [agentgateway](https://github.com/agentgateway/agentgateway) standalone (non-Kubernetes) in **Docker**, with the admin UI's **Costs / Analytics** dashboard pre-populated by generated mock fleet traffic — in a single command.

## Quick start (one command)

```sh
export OPENAI_API_KEY='sk-...'
./setup.sh
```

Then open the dashboard: <http://localhost:15000/ui/> → **Costs** / **Analytics**.

| URL | What it is |
|-----|------------|
| <http://localhost:15000/ui/> | UI on the **admin interface** (`config.adminAddr`) — always on |
| <http://localhost:8081/ui/> | UI on the **public `ui` gateway** (`ui.gateways`) — see [Gateways](#gateways) |
| <http://localhost:4000> | OpenAI-compatible LLM endpoint (`gateways.llm`) |

Teardown:

```sh
docker rm -f agw-cost-demo && docker volume rm agw-cost-demo-data
```

### What `setup.sh` does

1. **Preflight** — checks for `docker`, a running Docker daemon, `curl`, `OPENAI_API_KEY`, and a Python runner (`uv` preferred, else `python3 ≥ 3.11`).
2. **Fetches the generator** — downloads [`gen-mock-logs.py`](https://github.com/sebbycorp/Instruqt-demos/blob/main/01-ai-cost-webinar-workshop/assets/gen-mock-logs.py) (skips if already present).
3. **Generates mock data** — writes `data/data.db`, a SQLite database using the **same `request_logs` schema agentgateway logs to** (5000 requests across 7 days by default).
4. **Uses the committed `config.yaml`** — it does **not** generate it (see [Config ownership](#config-ownership)). It reads the gateway ports out of the file, fails early if any is already in use, and publishes exactly those.
5. **Seeds a Docker volume & runs** — copies the generated DB into the `agw-cost-demo-data` named volume, then starts the `agw-cost-demo` container mounting the config, catalog, and volume.

### Gateways

`config.yaml` declares named **gateways** — the entrypoints that features attach to by name:

```yaml
gateways:
  llm:
    port: 4000
  ui:
    port: 8081

llm:
  gateways: [llm]     # LLM routes on :4000
  models: [...]

ui:
  gateways: [ui]      # UI also served on :8081, on top of the admin interface
```

This matters beyond tidiness: **the admin UI's gateway pickers read `config.gateways` and nothing else.** The older `llm.port:` / `mcp.port:` shorthand still works and still creates real listeners, but the schema marks it *"Deprecated; use `gateways` instead"* and it produces no entry in `gateways`, so **UI Settings → Public UI gateway** shows *"No gateways configured — Add a gateway before exposing the UI"* and the UI access policies (OIDC, JWT, API key, CORS…) stay greyed out with *"UI policies require the UI to be exposed on a gateway."*

`setup.sh` derives its published Docker ports from this block, so changing a port in `config.yaml` is the only edit needed.

> ⚠️ The public UI gateway is **unauthenticated**. `setup.sh` binds it to `127.0.0.1` only. Add `ui.policies.oidc` before exposing it beyond loopback — the schema itself notes it is *"strongly recommended to utilize authentication (typically OIDC) when exposing the UI externally."*

MCP is present but commented out. With `targets: []` the endpoint only answers `503 mcp: no backends configured`, so it ships off; uncomment the `mcp` gateway and the `mcp:` block together to enable it.

### Config ownership

`config.yaml` is the **source of truth** and is committed. `setup.sh` mounts it as-is.

The admin UI can write this file back — every Save in UI Settings or a policy editor `PUT`s to `/api/config`, which re-serializes the whole file and **drops all comments**. That's expected; `git diff config.yaml` shows you exactly what the UI changed. Earlier versions of this demo regenerated `config.yaml` from a heredoc on every run, which silently discarded those UI edits — that's why generation was removed.

### How the mock data reaches the dashboard

The admin UI's Costs/Analytics pages read from `config.database`. The generator writes the **same `request_logs` schema** the gateway itself uses, so the gateway shows the generated traffic immediately — no live calls required. Any real calls you make are appended to the same DB and show up alongside the mock data.

```
gen-mock-logs.py ─writes─▶ ./data/data.db ─seed─▶ volume:/data/data.db ◀─reads/writes─ agentgateway (Docker)
                                                          │                                  │
                                                  same request_logs                  admin UI :15000/ui
                                                      schema                         Costs / Analytics
```

> **Why a named volume (not a host bind mount)?** On Docker Desktop for macOS, SQLite's write locking / WAL fail over the bind-mount filesystem (`disk I/O error`, code 522) — the gateway could read seeded data but never append live calls. A named volume lives in the Linux VM's real filesystem, where SQLite works. The container also runs as `--user 0:0` so it can create the WAL files in the root-owned volume. Inspect the live DB any time with:
>
> ```sh
> docker cp agw-cost-demo:/data /tmp/agw-data && sqlite3 /tmp/agw-data/data.db 'SELECT COUNT(*) FROM request_logs;'
> ```
>
> (Copy the whole `/data` dir, not just `data.db`, so SQLite replays the `-wal` file.)

### Make a live call (also logged to the dashboard)

```sh
curl -s http://localhost:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-4.1","messages":[{"role":"user","content":"Say hi in 3 words."}],"max_tokens":20}' | jq .
```

### Customize

| Variable         | Default      | Purpose                       |
|------------------|--------------|-------------------------------|
| `OPENAI_API_KEY` | *(required)* | Live OpenAI route credential  |
| `VERSION`        | `v1.4.0`     | agentgateway Docker image tag |
| `REQUESTS`       | `5000`       | Mock request rows to generate |
| `DAYS`           | `7`          | Days of history to backfill   |

```sh
REQUESTS=20000 DAYS=30 ./setup.sh   # heavier dataset
```

> `data/`, `*.db`, and the fetched `gen-mock-logs.py` are git-ignored — they're regenerated by `setup.sh`.

---

# Install agentgateway locally — manual reference

The steps below cover installing and running agentgateway standalone by hand (binary, install script, or Docker) — useful if you want to go beyond the dashboard demo above.

> **Release:** [`v1.3.0-beta.1`](https://github.com/agentgateway/agentgateway/releases/tag/v1.3.0-beta.1)

## Prerequisites

- macOS, Linux, or Windows
- `curl`, and `jq` (optional, for pretty-printing test output)
- For the MCP quickstart: Node.js / `npx`

## 1. Install

### Option A — install script (recommended)

```sh
curl -sL https://agentgateway.dev/install | bash
```

This installs the `agentgateway` binary (and the `agctl` CLI) onto your `PATH`.

Verify:

```sh
agentgateway --version
```

### Option B — download the release binary directly

Pick the asset for your platform from the [v1.4.0 release](https://github.com/agentgateway/agentgateway/releases/tag/v1.4.0):

| Platform        | agentgateway binary             | CLI                       |
|-----------------|---------------------------------|---------------------------|
| macOS (Apple)   | `agentgateway-darwin-arm64`     | `agctl-darwin-arm64`      |
| Linux (x86_64)  | `agentgateway-linux-amd64`      | `agctl-linux-amd64`       |
| Linux (arm64)   | `agentgateway-linux-arm64`      | `agctl-linux-arm64`       |
| Windows (x86_64)| `agentgateway-windows-amd64.exe`| `agctl-windows-amd64.exe` |

Example (macOS Apple Silicon):

```sh
VERSION=v1.4.0
BASE=https://github.com/agentgateway/agentgateway/releases/download/$VERSION

# Download
curl -sL -o agentgateway "$BASE/agentgateway-darwin-arm64"
curl -sL -o agentgateway.sha256 "$BASE/agentgateway-darwin-arm64.sha256"

# Verify checksum
shasum -a 256 -c <(echo "$(cat agentgateway.sha256)  agentgateway")

# Install
chmod +x agentgateway
sudo mv agentgateway /usr/local/bin/
agentgateway --version
```

### Option C — Docker

```sh
docker run -v ./config.yaml:/config.yaml -p 3000:3000 \
  -p 127.0.0.1:15000:15000 -e ADMIN_ADDR=0.0.0.0:15000 \
  cr.agentgateway.dev/agentgateway:v1.3.0-beta.1 \
  -f /config.yaml
```

- Mounts your local `config.yaml` into the container at `/config.yaml`.
- Publishes the proxy/MCP listener on `3000` and binds the admin UI to `127.0.0.1:15000` (loopback only).
- `ADMIN_ADDR=0.0.0.0:15000` makes the admin server listen on all interfaces inside the container so the published port reaches it.

## 2. Create a config file

Pick one of the quickstarts below and save it as `config.yaml`.

### MCP server (stdio)

```yaml
mcp:
  port: 3000
  targets:
  - name: server-everything
    stdio:
      cmd: npx
      args:
      - -y
      - "@modelcontextprotocol/server-everything"
```

### LLM proxy (OpenAI)

```yaml
llm:
  models:
  - name: gpt-3.5-turbo
    provider: openAI
    params:
      model: gpt-3.5-turbo
      apiKey: "$OPENAI_API_KEY"
```

```sh
export OPENAI_API_KEY='<your-api-key>'
```

## 3. Run

```sh
agentgateway -f config.yaml
```

- Proxy/MCP listener: `http://localhost:3000`
- Admin UI: `http://localhost:15000/ui/`

> Change the admin address with `adminAddr: localhost:9090` under a `config:` section if `15000` is taken.

## 4. Test

### MCP

Open the built-in playground, connect, list tools, and run the `echo` tool:

```
http://localhost:15000/ui/playground/
```

### LLM

```sh
curl -s http://localhost:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}]
  }' | jq .
```

## References

- Release notes: <https://github.com/agentgateway/agentgateway/releases/tag/v1.3.0-beta.1>
- Standalone docs: <https://agentgateway.dev/docs/standalone/latest/quickstart/>
- Admin UI: <https://agentgateway.dev/docs/standalone/latest/operations/ui>
