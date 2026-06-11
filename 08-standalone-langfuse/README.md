# agentgateway → Langfuse (Minimal MVP)

**Langfuse is on a separate VM (172.16.10.112:3000).**  
You want the simplest possible working tracing. No collector. No extra containers. No production setup.

### This is all you need for MVP

- `.env` (already has your keys)
- `config.yaml` (uses `${LANGFUSE_AUTH_STRING}` placeholder)
- `run.sh` (handles loading + substitution for you)

**You can ignore or delete these files for the MVP:**
- `otel-collector-config.yaml`
- `docker-compose.langfuse.yaml`

---

## Recommended way to run (MVP)

Use the helper script — it handles loading `.env` and substituting the secret:

```bash
# One-time setup
chmod +x run.sh

# Optional network check
curl -I http://172.16.10.112:3000 || echo "Cannot reach Langfuse VM"

# Run
./run.sh
```

Send some requests through the gateway (port 3000), then check traces in your Langfuse at `http://172.16.10.112:3000`.

---

## How it actually sends (why no collector is needed)

In `config.yaml` we have:

```yaml
config:
  tracing:
    otlpEndpoint: http://172.16.10.112:3000/api/public/otel
    otlpProtocol: http
    headers:
      Authorization: "Basic ${LANGFUSE_AUTH_STRING}"
      x-langfuse-ingestion-version: "4"
    randomSampling: true
```

- `otlpProtocol: http` is required (Langfuse does not accept gRPC OTLP yet).
- The endpoint goes straight to your Langfuse VM on port 3000.
- Langfuse has a built-in OTLP receiver at `/api/public/otel`.
- The gateway machine just needs network access to 172.16.10.112:3000.

That's the entire MVP data path: **agentgateway (HTTP OTLP) → Langfuse VM**.

No middle collector is required.

---

## If you ever want the collector later

Only use it if you decide you want gRPC from agentgateway or need batching/filtering at scale.  
For now you don't.

---

## Important

- The `run.sh` script loads `.env` for you. You no longer need to manually do `set -a && source .env`.
- `.env` is gitignored. Do not commit it.
- If traces don't appear:
  1. Check that the gateway machine can reach `172.16.10.112:3000` (the curl test above).
  2. Look at the startup logs — the tracing section should now show the real `Authorization: Basic cG...` (not `${LANGFUSE_AUTH_STRING}`).

This is deliberately the smallest possible working setup.

---

## What went wrong in your run

The error:

```
Error: parse: ... Syntax error: token recognition error at: '$'
| Basic ${LANGFUSE_AUTH_STRING}
```

Happened because:

- `config.yaml` contained the placeholder `Basic ${LANGFUSE_AUTH_STRING}` (good for keeping secrets out of the file).
- You correctly did `source .env` in your shell.
- **But** the `agentgateway` binary itself does **not** expand `${VAR}` when reading the YAML config file.
- It took the literal string and tried to parse it as a CEL expression (the gateway uses CEL in many config places). `$` and `}` are invalid in that context.

The parsed config dump in the logs even showed the unsubstituted value.

The new `run.sh` solves this by doing the substitution into a temp file right before launching the binary. This is a very common pattern for proxies that don't do env expansion natively (Envoy-style tools, etc.).

Now it should work cleanly for your MVP.