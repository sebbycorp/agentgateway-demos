# Standalone AgentGateway → Amazon Bedrock (Claude)

Run the `agentgateway` binary directly against `config.yaml` (no Kubernetes) to proxy chat completions to Amazon Bedrock Claude models in `us-east-2`.

## Prerequisites

- The `agentgateway` binary on `PATH` — see the [quickstart](https://agentgateway.dev/docs/quickstart/).
- A populated `../.env`. Either run `../provision-aws.sh` to generate one, or copy `../.env.example` to `../.env` and fill in real values.

## Auth modes

`run.sh` picks auth by `AUTH_MODE` (default `creds`) and loads everything from `../.env`:

| `AUTH_MODE` | Required in `../.env` |
|-------------|------------------------|
| `creds`     | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (optional `AWS_SESSION_TOKEN`) |
| `apikey`    | `AWS_BEARER_TOKEN_BEDROCK` |

Auth is ambient: the agentgateway process inherits these from its environment. No secret is ever written into the tracked `config.yaml`.

## Run

```sh
./run.sh
```

In another shell:

```sh
./test.sh
```

Expected output ends with:

```
PASS: Bedrock reachable via standalone AgentGateway
```

## Admin UI

<http://localhost:15000/ui/> — proxy/chat listener is on `:3000`.

## Swap the model

Edit `params.model` in `config.yaml` — for example, set it to `us.anthropic.claude-sonnet-4-6` to use Sonnet instead of Haiku.
