# Render image pack: standalone agentgateway

Build [`Dockerfile`](./Dockerfile) on Render: a static Go entrypoint writes `/config/.htpasswd` and a seed `config.yaml` (UI `basicAuth` plus the lab OpenAI model, virtual keys, and optional GitHub MCP), then `exec`s the official `v1.5.0` binary. The runtime includes **Node + `npx`** for stdio MCP. Do **not** pull the bare official image (`runtime: image`) — empty `/config` auto-gen serves `/ui/` with **no auth**.

How-to (architecture, screenshots, virtual keys, HTTPS curls): **[`34-render-deploy-agw`](../34-render-deploy-agw)**.

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/sebbycorp/agentgateway-demos)

The button reads **`render.yaml` at the repo root** (duplicate of [`render.yaml`](./render.yaml) here). Blueprint path from the dashboard: `render.yaml` or `deploy/render.yaml`. It **builds** this Dockerfile (`dockerfilePath: ./deploy/Dockerfile`, context `./deploy`). Disk is **`agw-config`** at **`/config`** (1 GB; not on Free). Auto-deploy is on for commits that touch `deploy/`.

Public URL is **HTTPS** on Render’s `:443` → container `PORT=4000`. Do not publish admin `:15000` (loopback-only).

| URL | What it is |
|-----|------------|
| `https://<service>.onrender.com/ui/` | UI. Browser basic-auth (`UI_USER` / `UI_PASSWORD`). |
| `https://<service>.onrender.com/v1/chat/completions` | OpenAI-compatible LLM. **Not** covered by `ui.policies`. |

## Environment

Set these in the Render Environment tab (or the Blueprint prompt). Never commit real keys.

| Variable | Required | Purpose |
|----------|----------|---------|
| `UI_PASSWORD` | **Yes** | Entrypoint writes `/config/.htpasswd` every start. Exits 1 if unset. |
| `UI_USER` | No | Basic-auth username. Default `admin`. |
| `PORT` | **Yes** | Must be `4000`. Render proxies `$PORT` (default `10000`); the gateway always listens on 4000. |
| `OPENAI_API_KEY` | For OpenAI | Expanded as `$OPENAI_API_KEY` when you add a model. |
| `ANTHROPIC_API_KEY` | Optional | Same pattern. |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | No | Optional. Not in the Blueprint prompt. Set it to seed GitHub remote MCP. |

See [`.env.example`](./.env.example). First boot writes the lab config: OpenAI wildcard (`$OPENAI_API_KEY`) and three placeholder virtual keys. GitHub remote MCP (`$GITHUB_PERSONAL_ACCESS_TOKEN`) is added only when that env var is set. Set provider keys in the dashboard; do not add the same objects again in the UI unless you are customizing.

Stdio MCP stays on the same `default` gateway (`https://<service>.onrender.com/mcp`):

```yaml
mcp:
  gateways: [default]
  targets:
  - name: server-everything
    stdio:
      cmd: npx
      args: ["-y", "@modelcontextprotocol/server-everything"]
```

## Persistence and security

Mount **`/config`** (Blueprint disk). That holds `.htpasswd`, seed `config.yaml`, and `data.db`. This image runs as **root** so the volume is writable.

`ui.policies.basicAuth` `mode: strict` is **demo-grade** behind Render TLS. Unauthenticated `GET /ui/` is **401**. OIDC: [Secure the UI](https://agentgateway.dev/docs/standalone/latest/documentation/setup/ui/secure-ui/). Health checks must not `GET /ui/` — this pack uses TCP.

## Local check (same image)

```sh
mkdir -p /tmp/agw-config
docker build -t agw-paas ./deploy
docker run --rm --name agw-paas \
  -v /tmp/agw-config:/config \
  -p 4000:4000 \
  -e UI_PASSWORD=change-me \
  -e OPENAI_API_KEY \
  agw-paas

curl -sI http://localhost:4000/ui/          # 401
curl -sI -u admin:change-me http://localhost:4000/ui/   # 200
```

```sh
cd deploy && go test -count=1 ./...
```

## References

- [Install with Docker](https://agentgateway.dev/docs/standalone/latest/setup/install/docker/)
- [Launch the UI](https://agentgateway.dev/docs/standalone/latest/documentation/setup/ui/launch-ui/)
- [Secure the UI (OIDC)](https://agentgateway.dev/docs/standalone/latest/documentation/setup/ui/secure-ui/)
- [Basic authentication](https://agentgateway.dev/docs/standalone/latest/configuration/security/basic-authn/)
- [Render Blueprint spec](https://render.com/docs/blueprint-spec) · [Deploy to Render button](https://render.com/docs/deploy-to-render)
