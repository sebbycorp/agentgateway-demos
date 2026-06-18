# Install agentgateway locally — v1.3.0-beta.1

Steps to install and run [agentgateway](https://github.com/agentgateway/agentgateway) standalone (non-Kubernetes) on your machine using the latest beta release.

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

Pick the asset for your platform from the [v1.3.0-beta.1 release](https://github.com/agentgateway/agentgateway/releases/tag/v1.3.0-beta.1):

| Platform        | agentgateway binary             | CLI                       |
|-----------------|---------------------------------|---------------------------|
| macOS (Apple)   | `agentgateway-darwin-arm64`     | `agctl-darwin-arm64`      |
| Linux (x86_64)  | `agentgateway-linux-amd64`      | `agctl-linux-amd64`       |
| Linux (arm64)   | `agentgateway-linux-arm64`      | `agctl-linux-arm64`       |
| Windows (x86_64)| `agentgateway-windows-amd64.exe`| `agctl-windows-amd64.exe` |

Example (macOS Apple Silicon):

```sh
VERSION=v1.3.0-beta.1
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
