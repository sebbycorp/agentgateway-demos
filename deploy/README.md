# One-click PaaS: standalone agentgateway

Deploy the official OSS Docker image — [`cr.agentgateway.dev/agentgateway:v1.5.0`](https://agentgateway.dev/docs/standalone/latest/setup/install/docker/) — to Render, Railway, or Fly.io.

This pack follows the documented **empty `/config` directory** path. On first start the gateway writes `config.yaml` plus a SQLite database into that volume. The generated file attaches the UI to the `default` gateway on **port 4000**.

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/sebbycorp/agentgateway-demos)
[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new)

Render's button applies the Blueprint at the repo root (`render.yaml`, a copy of [`render.yaml`](./render.yaml) in this folder). Railway has no first-party marketplace template — the Railway button opens a blank project; follow **Railway** below (or the community template noted there). Fly is `flyctl` from this directory.

## What to open after deploy

| URL | What it is |
|-----|------------|
| `https://<your-host>/ui/` | UI on the **gateway** (generated config: `ui.gateways: default`) |
| `https://<your-host>/v1/chat/completions` | OpenAI-compatible LLM endpoint, after you add a model |

Do **not** publish admin `:15000`. In the container that address is loopback-only; publishing it does not make the admin UI reachable. The supported path is the gateway port. Confirm the logged address (`serving UI at http://…:4000/ui`) if the path ever changes.

## Environment variables

Set these in the platform dashboard (or the Render Blueprint prompt). Never commit real keys.

| Variable | Required | Purpose |
|----------|----------|---------|
| `OPENAI_API_KEY` | For OpenAI models | Substituted as `$OPENAI_API_KEY` when you add a model |
| `ANTHROPIC_API_KEY` | Optional | Same pattern for Anthropic |
| `PORT` | **Required on Render and Railway** — must be `4000` | Those platforms proxy to `$PORT` (Render default `10000`, Railway often `8080`). The generated gateway **does not** read `$PORT`; it always listens on 4000. |
| `RAILWAY_RUN_UID` | **Required on Railway** — must be `0` | Official image USER is `65532`. Railway volumes are root-owned; without this the process cannot write `/config`. |

Add any other provider key the UI or `config.yaml` references the same way (`$GEMINI_API_KEY`, …). See [`.env.example`](./.env.example).

The first boot has **no models**. Open `/ui/`, add a provider/model (or edit `/config/config.yaml` on the volume), then call `/v1/chat/completions`.

## Persistence

Mount a writable disk/volume at **`/config`**. That is where the gateway generates `config.yaml` and `data.db`. Without it, config and analytics reset on every deploy. The published image runs as UID **65532**; the volume must be writable by that user, or the process must run as root (`RAILWAY_RUN_UID=0`, Fly `Dockerfile` `USER 0`).

| Platform | How |
|----------|-----|
| Render | Blueprint `disk.mountPath: /config` (paid plan; disks are not available on Free) |
| Railway | Not expressible in `railway.toml` — attach after create (see Railway below) |
| Fly | `[mounts]` `destination = "/config"` (`initial_size = "1gb"` on first launch) |

## Security (demo only)

A public UI **without OIDC** is for demos. Anyone who can reach `https://<host>/ui/` can change config. Before sharing a URL, add [`ui.policies.oidc`](https://agentgateway.dev/docs/standalone/latest/documentation/setup/ui/secure-ui/) (and prefer a dedicated UI gateway). Platform TLS terminates at the edge; that is not UI authentication.

---

## Render

1. Click **Deploy to Render** above, or open  
   `https://render.com/deploy?repo=https://github.com/sebbycorp/agentgateway-demos`
2. Paste `OPENAI_API_KEY` (and optionally `ANTHROPIC_API_KEY`) when prompted.
3. Deploy. Open `https://<service>.onrender.com/ui/`.

The button reads **`render.yaml` at the repo root**. That file is a duplicate of [`render.yaml`](./render.yaml) here. If you create a Blueprint from the Dashboard instead, set **Blueprint Path** to `deploy/render.yaml` (or `render.yaml`).

The Blueprint pulls `cr.agentgateway.dev/agentgateway:v1.5.0` (`runtime: image`), health-checks `GET /ui/` on port 4000, and mounts a 1 GB disk at `/config`. `autoDeploy` is off so pushes to this demos repo do not redeploy every copy.

Manual path (no Blueprint): **New → Web Service → Existing Image** → `cr.agentgateway.dev/agentgateway:v1.5.0`. Set `PORT=4000`, health check `/ui/`, disk mount `/config`.

---

## Railway

**This pack** uses the official image, public port **4000**, and a `/config` volume. A community template ([`alphasecio/agentgateway`](https://github.com/alphasecio/agentgateway)) exists and fronts MCP `:3000` plus admin `:15000` with Caddy — different layout, not this first-party pack.

### Option A — Docker image (preferred)

1. [New project](https://railway.com/new) → **Docker Image** → `cr.agentgateway.dev/agentgateway:v1.5.0`
2. Variables — all of these, or the deploy will not serve on 4000 / cannot write `/config`:
   - `PORT=4000` (required; Railway health-checks `$PORT`, not the image `EXPOSE`)
   - `RAILWAY_RUN_UID=0` (required; image USER is `65532`, volumes are root-owned)
   - `OPENAI_API_KEY=…`
   - optionally `ANTHROPIC_API_KEY`
3. **Volume** → mount path `/config` (CLI: `railway volume add --mount-path /config`).
4. **Networking** → generate a public domain (target port **4000** if asked).
5. Open `https://<your-app>.up.railway.app/ui/`.

### Option B — this repo

1. New project → **GitHub** → `sebbycorp/agentgateway-demos`.
2. Set the service **root directory** to `deploy` (uses [`Dockerfile`](./Dockerfile) + [`railway.toml`](./railway.toml)).  
   If the root stays the repo root, Railway uses [`/railway.toml`](../railway.toml) (`dockerfilePath = deploy/Dockerfile`).
3. Set the same variables as option A (`PORT=4000`, `RAILWAY_RUN_UID=0`, provider keys) and attach `/config`. `railway.toml` cannot set `PORT` or volumes.

`railway.toml` cannot declare volumes. New Railway services also no longer pick up Config as Code automatically (legacy `railway.toml` hard-cutoff 2026-12-01) — option A is the durable path.

---

## Fly.io

From a machine with [`flyctl`](https://fly.io/docs/flyctl/install/) and this repo:

Prefer creating the app without rewriting this `fly.toml` (plain `fly launch` can overwrite `[build]`, `internal_port`, and the `/config` mount):

```sh
cd deploy
fly apps create                 # pick a unique name
fly secrets set OPENAI_API_KEY=sk-... -a <name>
# optional: fly secrets set ANTHROPIC_API_KEY=... -a <name>
fly deploy -a <name> -c fly.toml
```

`fly deploy` creates the `agw_config` volume (1 GB) on first deploy via `initial_size`. If it does not:

```sh
fly volumes create agw_config --region iad --size 1 --yes -a <name>
fly deploy -a <name> -c fly.toml
```

Alternative: `fly launch --copy-config --no-deploy` then `fly deploy`. `--copy-config` keeps this file; skip it and the scanner may replace it.

[`fly.toml`](./fly.toml) sets `internal_port = 4000`, `force_https`, and mounts `agw_config` at `/config`. It builds [`Dockerfile`](./Dockerfile) (`FROM` the official image, `USER 0`) so the process can write the volume — the published image runs as UID `65532`. Health check is `GET /ui/` (Fly does not follow redirects; the trailing slash matters).

Open `https://<app>.fly.dev/ui/`.

---

## Local check (same image)

```sh
mkdir -p /tmp/agw-config
docker run --rm --name agw-paas \
  -v /tmp/agw-config:/config \
  -p 4000:4000 \
  -e OPENAI_API_KEY \
  cr.agentgateway.dev/agentgateway:v1.5.0
```

Open <http://localhost:4000/ui/>. You should see `config.yaml` and `data.db` appear under `/tmp/agw-config`.

## References

- [Install with Docker](https://agentgateway.dev/docs/standalone/latest/setup/install/docker/)
- [Launch the UI](https://agentgateway.dev/docs/standalone/latest/documentation/setup/ui/launch-ui/)
- [Secure the UI (OIDC)](https://agentgateway.dev/docs/standalone/latest/documentation/setup/ui/secure-ui/)
- [Render Blueprint spec](https://render.com/docs/blueprint-spec) · [Deploy to Render button](https://render.com/docs/deploy-to-render)
- [Railway Docker images](https://docs.railway.com/services) · [Volumes](https://docs.railway.com/volumes)
- [Fly `fly.toml`](https://fly.io/docs/reference/configuration/) · [Volumes](https://fly.io/docs/launch/volume-storage/)
