# 16 — API-key-scoped token budgets (standalone v1.5.0)

Demonstrate the **new** AgentGateway **1.5.0 standalone** feature: rolling **token or dollar budgets attached to a virtual API key** ([agentgateway/agentgateway#3143](https://github.com/agentgateway/agentgateway/pull/3143), [v1.5.0](https://github.com/agentgateway/agentgateway/releases/tag/v1.5.0)).

Budgets live on the key itself (`llm.policies.apiKey.keys[].budgets`), persist through `config.database` (SQLite is enough), and are checked in-process.

> Folder name: this demo was requested as `11-api-key-scoped-token-budgets`, but `11-xaa-cross-app-access` already occupies slot 11. It is `16-…` — the next free sequential OSS demo after `15-github-copilot`.

## Why standalone + a database

| | v1.5.0 standalone |
|---|---|
| Where the budget lives | `LocalAPIKey.budgets[]` on the virtual key |
| Enforcement | In-process `BudgetPolicy` |
| Persistence | In-memory counters, flushed to SQLite/Postgres every 5s |
| Charge timing | **After** the LLM response, and only if the provider reports usage (Tokens) or the catalog can price the model (USD) |
| Window | `window.rolling` duration, **aligned to the Unix epoch** (not first request) |
| Over-limit | `onBudgetExceeded: Block` → HTTP 429 `budget_exceeded` + `Retry-After`; or `Audit` (log, do not block) |
| Status | `GET /api/budgets/status` and the admin UI **Virtual API Keys** page |

v1.5.0 source (`crates/agentgateway/src/http/budget/mod.rs`) refuses to register budgets unless `config.database` is set: *"API key budgets require config.database to be configured."* Hybrid here means **memory + periodic DB flush**.

Windows are epoch-aligned: `1h` follows UTC clock hours, `24h` starts at midnight UTC, `30d` is consecutive 30-day periods from 1970-01-01 — not “starting when the first request arrives.”

## What you will see

The demo calls **`openai/gpt-5.5`** — 5 USD/1M input, 30 USD/1M output, so a ~200-token answer costs about **0.005 USD** and dollar meters move in figures you can actually read.

Four virtual keys: two token budgets that differ only in `onBudgetExceeded`, and two dollar budgets.

| Key | `metadata.name` | Budget | Action | Model | Expected |
|-----|-----------------|--------|--------|-------|----------|
| `sk-demo-block` | `demo-block` | 1000 Tokens / 1h | `Block` | gpt-5.5 | ~200 tokens per call, so calls 1-5 are **200** and the next is **429** `error.code=budget_exceeded` + `Retry-After` |
| `sk-demo-audit` | `demo-audit` | 1000 Tokens / 1h | `Audit` | gpt-5.5 | Calls keep **200**; `/api/budgets/status` still shows `used` / `exceeded` |
| `sk-demo-cost` | `demo-cost` | 0.02 USD / 1h | `Block` | gpt-5.5 | `used` climbs ~0.005 per call, then **429** on the call after it crosses 0.02 |
| `sk-demo-nano` | `demo-nano` | 0.02 USD / 1h | `Audit` | gpt-4.1-nano | Charges ~0.000055 per call — and **only** if the models.dev catalog layer loaded |

Charge is post-response, so the call that *crosses* the limit still succeeds. The *next* Block-key call is denied.

Tokens charge straight from `usage.total_tokens`. **USD charges `prompt_tokens x input_rate + completion_tokens x output_rate`, read out of the model cost catalog** — so a dollar budget is only as good as that catalog. See [Cost catalog](#cost-catalog-why-usd-budgets-read-000).

`sk-demo-nano` exists to prove that layer: the image's own catalog has no `gpt-4.1-nano` entry, so a nonzero charge on that key can only come from the fetched models.dev data.

### gpt-5.5 is a reasoning model

Two consequences for every request in this demo:

- Send **`max_completion_tokens`**, not `max_tokens` — OpenAI rejects the latter with `Unsupported parameter: 'max_tokens' is not supported with this model.`
- `completion_tokens` **includes** `completion_tokens_details.reasoning_tokens`, and models.dev sets no separate `reasoning` rate for gpt-5.5, so reasoning bills at the output rate. Per-call token counts vary run to run because reasoning length does; the tests loop until the budget trips rather than assuming a fixed count.

`gpt-4.1-nano`, routed for `sk-demo-nano`, is not a reasoning model and takes plain `max_tokens`.

### Dialling the numbers

| Where | Knob |
|---|---|
| `config.yaml` | `budgets[].limit.amount` — 1000 Tokens, 0.02 USD |
| `test.sh` | `MAX_COMPLETION_TOKENS` (400), `PROMPT`, `MAX_TRIES` (10) |
| `mock-openai.py` | `PROMPT_TOKENS` / `COMPLETION_TOKENS` (150 / 350) for the offline path |

Bigger `MAX_COMPLETION_TOKENS` and a prompt that demands a longer answer are the fastest way to make one call cost more.

v1.5.0 also moved UI-created key IDs from `metadata.id` to reserved `metadata["agentgateway.dev/id"]` ([#3139](https://github.com/agentgateway/agentgateway/pull/3139)). Do not set `agentgateway.dev/*` yourself — user-supplied values under that prefix are rejected. Budget counters are keyed by the SHA-256 of the secret; `metadata.name` is the required **display** name (`API keys with budgets must have a metadata.name`).

## Cost catalog: why USD budgets read 0.00

`limit.unit: USD` charges nothing unless the gateway can price the model. Prices come from `config.modelCatalog`, a list of catalog files merged in order with later entries winning — the one config block v1.5.0 hot-reloads.

The image ships a curated `/base-costs.json` and uses it by default. It is a **subset**. It prices `gpt-5.5`, `gpt-4.1` and `gpt-4.1-mini`, but not `gpt-4.1-nano` — which was this demo's original model, and why its USD budget read 0.00 and never blocked: silently, with no error anywhere. An unpriced model simply costs nothing.

That is the whole failure mode, and it is invisible until you look for it. The demo now keeps both cases side by side: `gpt-5.5` is priced by either catalog, `gpt-4.1-nano` only by the models.dev layer.

The fix is to layer a fuller catalog on top. `setup.sh` fetches one from [models.dev](https://models.dev) and converts it:

```sh
curl -fsSL https://models.dev/api.json -o .runtime/models-dev-api.json
python3 models-dev-catalog.py .runtime/models-dev-api.json > .runtime/model-catalog.json
```

Use **`api.json`**, not `models.dev/models.json` — the latter is the flat canonical model list and carries no `cost` field at all.

`models-dev-catalog.py` maps models.dev provider ids onto the 19 provider keys AgentGateway looks models up under (`openai`, `anthropic`, `google` → `gcp.gemini`, `amazon-bedrock` → `aws.bedrock`, `github-copilot` → `copilot`, `fireworks-ai` → `fireworks`, …) and rewrites each `cost` block into `rates` / `tiers`:

| models.dev | AgentGateway `Rates` |
|---|---|
| `cost.input` / `cost.output` | `input` / `output` (per 1M tokens) |
| `cost.cache_read` / `cost.cache_write` | `cacheRead` / `cacheWrite` |
| `cost.reasoning` | `reasoning` (falls back to `output`) |
| `cost.input_audio` / `cost.output_audio` | `inputAudio` / `outputAudio` |
| `cost.tiers[].tier.size` (`type: context`) | `tiers[].contextOver` |

Result: **996 priced models across 19 providers**, a strict superset of the 932 in the shipped file, `gpt-4.1-nano` included.

Two traps the converter exists to avoid, both of which reject the **entire** file (`model catalog load failed; will load when the files become valid`) and with it every other model in it:

- `Money` accepts **at most 6 fractional digits**. models.dev carries IEEE-754 noise like `0.049999999999999996`, so every rate is rounded half-up to 6 places.
- `Money` is a decimal string, so `"1E-7"` is rejected. Rates are formatted with `Decimal`, never `str(float)`.

Knobs:

| Variable | Effect |
|---|---|
| `CATALOG_URL` | Override the feed (default `https://models.dev/api.json`) |
| `SKIP_MODEL_CATALOG=1` | Do not fetch; run on the image catalog alone. `sk-demo-cost` still charges (gpt-5.5 is in the image catalog); `sk-demo-nano` goes back to 0.00, so `./test.sh` fails at step 8 — that failure is the bug, reproduced |

The fetch is best-effort. If models.dev is unreachable, a previously converted `.runtime/model-catalog.json` is reused; failing that, setup warns and continues with the image catalog. Layering is per runtime:

| Runtime | `config.modelCatalog` |
|---|---|
| Docker | `/base-costs.json`, then `/model-catalog.json` (bind-mounted) |
| Host binary | the absolute `.runtime/model-catalog.json` path only — `/base-costs.json` lives inside the image, and `setup.sh` drops the entry rather than log a missing-file warning on every start |

To confirm it took effect:

```sh
docker logs agw-token-budgets 2>&1 | grep 'model catalog'
# info llm::catalog  model catalog loaded  providers=19 models=996
```

### Gotcha: dollar signs in this config file

The gateway expands env-var references over the **raw config text, comments included**, matching a `$` followed by uppercase letters or digits. A comment reading `$0.10/1M` makes startup fail with `error looking key '0' up: environment variable not found`. Spell prices out as `0.10 USD` in `config.yaml`. (Line 1's `$schema` survives only because it is lowercase.)

## Quick start (one command)

```sh
cd 16-api-key-scoped-token-budgets
# required — real OpenAI key (or put it in .env, see .env.example)
export OPENAI_API_KEY='sk-...'
./setup.sh
./test.sh
```

`./run.sh` is the same as `./setup.sh`. `./test.sh` expects a **fresh** window (run `./setup.sh` first). Re-running it in the same epoch-aligned `1h` window will see `sk-demo-block` already over limit.

| URL | What it is |
|-----|------------|
| <http://localhost:15000/ui/> | Admin UI — open **Keys** for per-key budget meters |
| <http://localhost:15000/api/budgets/status> | JSON snapshot (`?apiKeyName=demo-block` filters) |
| <http://localhost:4000> | OpenAI-compatible LLM listener |

Teardown:

```sh
./cleanup.sh
```

Image: `cr.agentgateway.dev/agentgateway:v1.5.0`. Override with `VERSION=v1.5.0 ./setup.sh`.

If Docker cannot start a container, `setup.sh` downloads the matching [v1.5.0 release binary](https://github.com/agentgateway/agentgateway/releases/tag/v1.5.0) and runs it on the host (`AGW_RUNTIME=binary` forces that path). SQLite then lives in `./data/data.db` instead of the named volume.

### What `setup.sh` does

1. **Preflight** — `docker`, a running daemon, `curl`, free ports from `config.yaml`.
2. **LLM path** — live OpenAI, using your real `OPENAI_API_KEY`. The key is **required**; setup exits rather than quietly swapping in a fake upstream. For a deliberately offline run, `USE_MOCK=1 ./setup.sh` starts `mock-openai.py` (stdlib HTTP server) which always reports **150 prompt + 350 completion = 500** total tokens, sized against the committed limits so both Block keys trip on the third call (0.01125 USD per gpt-5.5 call).
3. **Cost catalog** — `curl https://models.dev/api.json` → `models-dev-catalog.py` → `.runtime/model-catalog.json`, bind-mounted at `/model-catalog.json` and layered over the image's `/base-costs.json`. Best-effort; see [Cost catalog](#cost-catalog-why-usd-budgets-read-000).
4. **Named volume** — SQLite at `/data/data.db` in `agw-token-budgets-data`. Bind mounts break SQLite WAL on Docker Desktop macOS (`disk I/O error`, code 522); a named volume sits on the Linux VM filesystem. Same reason as `00-standalone-latest`.
5. **Run** — `docker run` the v1.5.0 image, loopback-published `:4000` and `:15000`. If that fails, the official v1.5.0 host binary is used instead.

`config.yaml` is the committed source of truth. The `USE_MOCK=1` path only injects `params.baseUrl` (a real `LocalLLMParams` field) into `.runtime/config.yaml` so the tracked file stays a valid live-OpenAI config.

## Curl examples

Unauthenticated (strict mode — should not be 200):

```sh
curl -s -o /tmp/out -w '%{http_code}\n' http://localhost:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-5.5","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":16}'
```

Success (Block key, first call):

```sh
curl -s http://localhost:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-demo-block' \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-5.5","messages":[{"role":"user","content":"Explain token-based rate limiting for LLM gateways in about 120 words."}],"max_completion_tokens":400}' | jq .
```

Status after that charge:

```sh
curl -s 'http://localhost:15000/api/budgets/status?apiKeyName=demo-block' | jq .
```

Block (once `used` has reached the 1000-token limit):

```sh
curl -sD - http://localhost:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-demo-block' \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-5.5","messages":[{"role":"user","content":"Explain token-based rate limiting for LLM gateways in about 120 words."}],"max_completion_tokens":400}'
```

Expected body (from v1.5.0 `ProxyError::BudgetExceeded`):

```json
{
  "error": {
    "message": "Budget exceeded",
    "type": "rate_limit_error",
    "code": "budget_exceeded"
  }
}
```

plus HTTP 429 and a `Retry-After` header (seconds left in the current epoch window).

Audit (still 200 after the same limit):

```sh
curl -s http://localhost:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-demo-audit' \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-5.5","messages":[{"role":"user","content":"Explain token-based rate limiting for LLM gateways in about 120 words."}],"max_completion_tokens":400}' | jq .
curl -s 'http://localhost:15000/api/budgets/status?apiKeyName=demo-audit' | jq .
```

USD budget (dollar usage priced from the cost catalog):

```sh
curl -s http://localhost:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-demo-cost' \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-5.5","messages":[{"role":"user","content":"Explain token-based rate limiting for LLM gateways in about 120 words."}],"max_completion_tokens":400}' | jq .
curl -s 'http://localhost:15000/api/budgets/status?apiKeyName=demo-cost' | jq '.budgets[].usage'
```

```json
{ "used": "0.004725", "remaining": "0.015275", "exceeded": false }
```

`0.004725` is 21 prompt tokens at 5 USD/1M plus 154 completion tokens at 30 USD/1M. A `used` of `0` here means the catalog cannot price the model — not that the budget is broken.

And the models.dev-only model, which the image catalog cannot price at all:

```sh
curl -s http://localhost:4000/v1/chat/completions \
  -H 'Authorization: Bearer sk-demo-nano' \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-4.1-nano","messages":[{"role":"user","content":"Explain token budgets in about 120 words."}],"max_tokens":400}' | jq .
curl -s 'http://localhost:15000/api/budgets/status?apiKeyName=demo-nano' | jq '.budgets[].usage'
```

```json
{ "used": "0.0000554", "remaining": "0.0199446", "exceeded": false }
```

## UI

Admin UI: <http://localhost:15000/ui/> → **LLM → Virtual API Keys**. Each key shows its budget name and a usage meter. The same data is `GET /api/budgets/status`.

Saving in the UI `PUT`s `/api/config` and re-serializes the file (comments are dropped). `git diff config.yaml` is the record of those edits.

**Virtual API Keys** (hero, 2000px) — after traffic, `demo-block` and `demo-audit` both show the `tokens` meter fully red at **100%**:

![Virtual API Keys with hourly token budgets exceeded at 100%](docs/06-keys-exceeded.png)

**Home** — Gateway Overview. LLM enabled, Virtual API Keys in the sidebar:

![Gateway Overview home](docs/01-home.png)

**LLM Costs** — captured before `setup.sh` layered in a catalog, so the page is empty. That empty state *is* the failure mode: a `limit.unit: USD` budget only charges when the gateway can price the model, so with no catalog every dollar meter reads 0.00. See [Cost catalog](#cost-catalog-why-usd-budgets-read-000). Token budgets do not need this page:

![LLM Costs with empty catalog](docs/03-costs.png)

**Status API** — raw `GET /api/budgets/status` after the same replay. Both keys are `exceeded: true` (`demo-audit` used 80/40 `Audit`, `demo-block` used 40/40 `Block`). These shots predate the retune to gpt-5.5, so they show the old 40-token limits and only the two token keys; the shapes are unchanged:

![GET /api/budgets/status JSON with both keys exceeded](docs/07-budgets-json-exceeded.png)

## Config (verified against the 1.5.0 schema)

Each budget, from `Budget` in the standalone schema:

| Field | Values |
|-------|--------|
| `name` | Stable name within the key |
| `limit.unit` | `USD` or `Tokens` |
| `limit.amount` | Number. Tokens must be whole; USD ≤ 6 fractional digits (`Money`) |
| `window.rolling` | Duration string, e.g. `1h`, `24h`, `30d` |
| `onBudgetExceeded` | `Audit` or `Block` |

`apiKey.mode` is `strict`. Provider credential is `$OPENAI_API_KEY` (expanded by the gateway from the environment), never committed. See [the gotcha](#gotcha-dollar-signs-in-this-config-file) about that same expansion running over comments.

## Files

| File | Role |
|------|------|
| `config.yaml` | Committed source of truth |
| `setup.sh` / `run.sh` | One-command Docker start |
| `models-dev-catalog.py` | models.dev `api.json` → AgentGateway cost catalog |
| `test.sh` | 9 checks: no-auth / 200 / status / `budget_exceeded` / Audit / USD charge + block / models.dev-only pricing |
| `cleanup.sh` | Container + volume + mock |
| `mock-openai.py` | Opt-in offline LLM (`USE_MOCK=1`), fixed 150 + 350 = 500 tokens per call |
| `docs/06-keys-exceeded.png` | Hero: Virtual API Keys at 2000px, both meters 100% |
| `docs/01-home.png` | Gateway Overview |
| `docs/03-costs.png` | LLM Costs (empty catalog) |
| `docs/07-budgets-json-exceeded.png` | `GET /api/budgets/status` after both keys exceeded |
| `.env.example` | `OPENAI_API_KEY=` |

## References

- Feature PR: <https://github.com/agentgateway/agentgateway/pull/3143>
- Release: <https://github.com/agentgateway/agentgateway/releases/tag/v1.5.0>
- Standalone schema: <https://agentgateway.dev/schema/config>
- Pricing feed: <https://models.dev/api.json> (site: <https://models.dev>)
- Sibling Docker demo: [`00-standalone-latest`](../00-standalone-latest)
