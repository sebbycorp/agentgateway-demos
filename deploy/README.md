# One-click PaaS: standalone agentgateway

Deploy a thin wrapper around the official OSS image — [`cr.agentgateway.dev/agentgateway:v1.5.0`](https://agentgateway.dev/docs/standalone/latest/setup/install/docker/) — to Render, Railway, or Fly.io.

The published image has **no shell** (`ENTRYPOINT=/app/agentgateway`). This pack **builds** [`Dockerfile`](./Dockerfile): a static Go entrypoint writes `/config/.htpasswd` and a seed `config.yaml` (official auto-gen shape plus `ui.policies.basicAuth`), then `exec`s the gateway. Do **not** run the bare official image on a public URL — empty `/config` auto-gen serves `/ui/` with **no auth**.

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/sebbycorp/agentgateway-demos)
[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new)

Render's button applies the Blueprint at the repo root (`render.yaml`, a copy of [`render.yaml`](./render.yaml) in this folder). Railway has no first-party marketplace template — the Railway button opens a blank project; follow **Railway** below. Fly is `flyctl` from this directory.

## What to open after deploy

| URL | What it is |
|-----|------------|
| `https://<your-host>/ui/` | UI on the **gateway**. Browser shows a **basic-auth** prompt (`UI_USER` / `UI_PASSWORD`). |
| `https://<your-host>/v1/chat/completions` | OpenAI-compatible LLM endpoint, after you add a model. **Not** covered by `ui.policies` — do not send the UI password here. |

Do **not** publish admin `:15000`. In the container that address is loopback-only; publishing it does not make the admin UI reachable. The supported path is the gateway port. Confirm the logged address (`serving UI at http://…:4000/ui`) if the path ever changes.

## Environment variables

Set these in the platform dashboard (or the Render Blueprint prompt). Never commit real keys or passwords.

| Variable | Required | Purpose |
|----------|----------|---------|
| `UI_PASSWORD` | **Required** | Entrypoint writes `/config/.htpasswd` every start. Process **exits 1** if unset. Generate in the dashboard (`sync: false` on Render). |
| `UI_USER` | Optional | Basic-auth username. Default `admin`. |
| `OPENAI_API_KEY` | For OpenAI models | Substituted as `$OPENAI_API_KEY` when you add a model |
| `ANTHROPIC_API_KEY` | Optional | Same pattern for Anthropic |
| `PORT` | **Required on Render and Railway** — must be `4000` | Those platforms proxy to `$PORT` (Render default `10000`, Railway often `8080`). The generated gateway **does not** read `$PORT`; it always listens on 4000. |
| `RAILWAY_RUN_UID` | **Required on Railway** — must be `0` | Official image USER is `65532`. Railway volumes are root-owned; without this the process cannot write `/config`. |

Add any other provider key the UI or `config.yaml` references the same way (`$GEMINI_API_KEY`, …). See [`.env.example`](./.env.example).

The first boot has **no models**. Open `/ui/` (after the login prompt), add a provider/model (or edit `/config/config.yaml` on the volume), then call `/v1/chat/completions`.

## Persistence

Mount a writable disk/volume at **`/config`**. That is where the entrypoint writes `.htpasswd` + seed `config.yaml`, and where the gateway keeps `data.db`. Without it, config and analytics reset on every deploy. The published image runs as UID **65532**; this Dockerfile runs as **root** so PaaS volumes are writable (`RAILWAY_RUN_UID=0` still required on Railway).

| Platform | How |
|----------|-----|
| Render | Blueprint `disk.mountPath: /config` (paid plan; disks are not available on Free) |
| Railway | Not expressible in `railway.toml` — attach after create (see Railway below) |
| Fly | `[mounts]` `destination = "/config"` (`initial_size = "1gb"` on first launch) |

An existing volume from the previous open pack (auto-gen `config.yaml` with no `ui.policies.basicAuth`) is **locked on next start**: the entrypoint injects `basicAuth` and keeps any models you already added.

## Security (demo-grade basic auth)

`ui.policies.basicAuth` `mode: strict` plus a file-based htpasswd (`{SHA}` lines). The browser prompts; unauthenticated `GET /ui/` is **401**. `{SHA}` / HTTP basic is **demo-grade** behind platform TLS — not a substitute for a real IdP.

**OIDC is the production upgrade** when you share a URL beyond a short demo. It needs an IdP and `OIDC_COOKIE_SECRET` (32 random bytes as 64 hex chars). This pack does **not** require OIDC for one-click. See [Secure the UI (OIDC)](https://agentgateway.dev/docs/standalone/latest/documentation/setup/ui/secure-ui/).

Inline htpasswd is **not** used: bcrypt hashes contain `$`, and agentgateway env-expands `$VARS` in config.

`ui.policies` applies only to the UI (and UI API on `/api`) on the listed gateway. LLM routes on the same port are unchanged.

Platform health checks must **not** `GET /ui/` (401 ≠ healthy). This pack uses TCP / omitted HTTP probe paths.

---

## Render

1. Click **Deploy to Render** above, or open  
   `https://render.com/deploy?repo=https://github.com/sebbycorp/agentgateway-demos`
2. Set `UI_PASSWORD` (required). Paste `OPENAI_API_KEY` (and optionally `ANTHROPIC_API_KEY`) when prompted.
3. Deploy. Open `https://<service>.onrender.com/ui/` and sign in with `UI_USER` / `UI_PASSWORD`.

The button reads **`render.yaml` at the repo root**. That file is a duplicate of [`render.yaml`](./render.yaml) here. If you create a Blueprint from the Dashboard instead, set **Blueprint Path** to `deploy/render.yaml` (or `render.yaml`).

The Blueprint **builds** [`Dockerfile`](./Dockerfile) (`runtime: docker`, `dockerfilePath: ./deploy/Dockerfile`). It does **not** pull the bare official image (`runtime: image` skips the entrypoint). Disk is 1 GB at `/config`. `autoDeploy` is off so pushes to this demos repo do not redeploy every copy.

Manual path (no Blueprint): **New → Web Service → Dockerfile** in this repo (`deploy/Dockerfile`, context `deploy`). Set `UI_PASSWORD`, `PORT=4000`, disk mount `/config`. Do not use **Existing Image** → `cr.agentgateway.dev/agentgateway:v1.5.0`.

---

## Railway

**This pack** builds the Dockerfile, public port **4000**, and a `/config` volume. A community template ([`alphasecio/agentgateway`](https://github.com/alphasecio/agentgateway)) exists and fronts MCP `:3000` plus admin `:15000` with Caddy — different layout, not this first-party pack.

### Option A — this repo (required for a locked UI)

1. [New project](https://railway.com/new) → **GitHub** → `sebbycorp/agentgateway-demos`.
2. Set the service **root directory** to `deploy` (uses [`Dockerfile`](./Dockerfile) + [`railway.toml`](./railway.toml)).  
   If the root stays the repo root, Railway uses [`/railway.toml`](../railway.toml) (`dockerfilePath = deploy/Dockerfile`).
3. Variables:
   - `UI_PASSWORD=…` (required)
   - `UI_USER=admin` (optional)
   - `PORT=4000` (required; Railway health-checks `$PORT`, not the image `EXPOSE`)
   - `RAILWAY_RUN_UID=0` (required; volumes are root-owned)
   - `OPENAI_API_KEY=…`
   - optionally `ANTHROPIC_API_KEY`
4. **Volume** → mount path `/config` (CLI: `railway volume add --mount-path /config`).
5. **Networking** → generate a public domain (target port **4000** if asked).
6. Open `https://<your-app>.up.railway.app/ui/` and sign in.

`railway.toml` cannot declare volumes or `UI_PASSWORD`. New Railway services also no longer pick up Config as Code automatically (legacy `railway.toml` hard-cutoff 2026-12-01) — still **build this Dockerfile**, do not point Railway at the official image.

### Option B — do not use the official image alone

A **Docker Image** service of `cr.agentgateway.dev/agentgateway:v1.5.0` skips the entrypoint. Empty `/config` auto-gen leaves `/ui/` open. Use option A.

---

## Fly.io

From a machine with [`flyctl`](https://fly.io/docs/flyctl/install/) and this repo:

Prefer creating the app without rewriting this `fly.toml` (plain `fly launch` can overwrite `[build]`, `internal_port`, and the `/config` mount):

```sh
cd deploy
fly apps create                 # pick a unique name
fly secrets set UI_PASSWORD=... -a <name>
fly secrets set OPENAI_API_KEY=sk-... -a <name>
# optional: fly secrets set ANTHROPIC_API_KEY=... -a <name>
# optional: fly secrets set UI_USER=admin -a <name>
fly deploy -a <name> -c fly.toml
```

`fly deploy` creates the `agw_config` volume (1 GB) on first deploy via `initial_size`. If it does not:

```sh
fly volumes create agw_config --region iad --size 1 --yes -a <name>
fly deploy -a <name> -c fly.toml
```

Alternative: `fly launch --copy-config --no-deploy` then `fly deploy`. `--copy-config` keeps this file; skip it and the scanner may replace it.

[`fly.toml`](./fly.toml) sets `internal_port = 4000`, `force_https`, and mounts `agw_config` at `/config`. It builds [`Dockerfile`](./Dockerfile). Health is TCP on `:4000` (not `GET /ui/`).

Open `https://<app>.fly.dev/ui/` and sign in.

---

## Local check (same image)

`UI_PASSWORD` is required. After boot, `/ui/` is 401 without credentials and 200 with them:

```sh
mkdir -p /tmp/agw-config
docker build -t agw-paas ./deploy
docker run --rm --name agw-paas \
  -v /tmp/agw-config:/config \
  -p 4000:4000 \
  -e UI_PASSWORD=change-me \
  -e OPENAI_API_KEY \
  agw-paas

# in another terminal
curl -sI http://localhost:4000/ui/          # 401
curl -sI -u admin:change-me http://localhost:4000/ui/   # 200
```

You should see `config.yaml`, `.htpasswd`, and `data.db` appear under `/tmp/agw-config`. A run without `UI_PASSWORD` exits immediately with `entrypoint: UI_PASSWORD is required…`.

To exercise the entrypoint without Docker:

```sh
cd deploy
go test -count=1 ./...
```

## References

- [Install with Docker](https://agentgateway.dev/docs/standalone/latest/setup/install/docker/)
- [Launch the UI](https://agentgateway.dev/docs/standalone/latest/documentation/setup/ui/launch-ui/)
- [Secure the UI (OIDC)](https://agentgateway.dev/docs/standalone/latest/documentation/setup/ui/secure-ui/)
- [Basic authentication](https://agentgateway.dev/docs/standalone/latest/configuration/security/basic-authn/)
- [Render Blueprint spec](https://render.com/docs/blueprint-spec) · [Deploy to Render button](https://render.com/docs/deploy-to-render)
- [Railway Docker images](https://docs.railway.com/services) · [Volumes](https://docs.railway.com/volumes)
- [Fly `fly.toml`](https://fly.io/docs/reference/configuration/) · [Volumes](https://fly.io/docs/launch/volume-storage/)
