# Intense Guardrails Testing

This guide extends the smoke test with adversarial and operational checks for
the agentgateway Enterprise + F5 AI Guardrails demo.

## Test Levels

Use the smallest test that answers your question.

| Level | Command | Purpose |
|---|---|---|
| Smoke | `./test.sh` | Fast validation that both routes and the demo scanners work |
| Harness smoke | `./run_harness.sh` | JSONL evidence for the default cases |
| Intense corpus | `HARNESS_CASES=harness/intense-cases.yaml ./run_harness.sh` | Evasion, streaming, multi-message, PII, and large-payload probes |
| Soak | `HARNESS_CASES=harness/intense-cases.yaml HARNESS_CONCURRENCY=25 HARNESS_REPEAT=4 ./run_harness.sh` | Repeated concurrent traffic through agentgateway and Guardrails |
| Fail-closed | `I_UNDERSTAND_FAIL_CLOSED_TEST_MUTATES_CLUSTER=1 harness/fail_closed_probe.sh` | Verifies Option C rejects traffic when ScanAPI is unreachable |

All harness runs write JSONL results. Override the output path when you want to
keep separate evidence files:

```bash
HARNESS_CASES=harness/intense-cases.yaml \
HARNESS_OUTPUT=harness/results-intense.jsonl \
./run_harness.sh
```

## Intense Corpus

`harness/intense-cases.yaml` includes:

- exact `project-titan` hits in Option A and Option C
- large prompts with the blocked keyword at different positions
- multi-message chat payloads
- JSON-shaped request payloads
- response-phase leakage probes
- streaming response checks
- repeated, JSON-shaped, and large-tail SSN redaction checks
- near-miss boundary checks that should not trigger the exact demo scanners
- obfuscation probes that expose scanner normalization gaps

The obfuscation probes are intentionally useful even when they fail. The demo
setup creates a simple custom keyword scanner for `project-titan` and a regex
scanner for dashed SSNs. If you want obfuscation resistance, add stronger F5
Guardrails scanners in the tenant and keep the same harness cases.

## Concurrency And Soak

Use concurrency to stress the full path:

```bash
HARNESS_CASES=harness/intense-cases.yaml \
HARNESS_CONCURRENCY=50 \
HARNESS_REPEAT=5 \
HARNESS_OUTPUT=harness/results-soak.jsonl \
./run_harness.sh
```

Review failures and latency:

```bash
jq -r 'select(.passed == false)' harness/results-soak.jsonl
jq -s 'map(.latency_ms) | {count:length, max:max, avg:(add / length)}' harness/results-soak.jsonl
```

The harness sends requests concurrently but keeps the same policy assertions:
blocked content must stay blocked, redacted content must not leak, and allowed
near-misses must still pass.

## Streaming

Streaming cases set `stream: true` in YAML. The harness collects the full SSE
body and applies the same `body_contains` and `body_not_contains` checks. This
does not prove that an intermediate client could not display early chunks before
completion; it proves that the gateway response body captured by the harness did
not contain forbidden text.

For production-grade streaming assurance, pair this harness with a client that
renders chunks as they arrive and fails as soon as forbidden content appears.

## Fail-Closed Probe

`harness/fail_closed_probe.sh` temporarily changes the adapter deployment:

```bash
kubectl set env -n agentgateway-system deployment/f5-guardrails-adapter F5_AISEC_URL=http://127.0.0.1:9
```

Then it sends a benign request to `/option-c` and expects HTTP `503`. This
confirms the request webhook does not bypass F5 ScanAPI when the adapter cannot
reach Guardrails. The script restores the original environment value before it
exits.

Run it only against a disposable demo cluster:

```bash
I_UNDERSTAND_FAIL_CLOSED_TEST_MUTATES_CLUSTER=1 harness/fail_closed_probe.sh
```

## agentgateway Enterprise UI

The demo installs the Solo/kagent Enterprise UI alongside Enterprise
agentgateway by default. The UI is installed from the management Helm chart and
connected to the agentgateway control plane in `agentgateway-system`.

Default demo values:

```bash
ENABLE_AGENTGATEWAY_UI=true
SOLO_UI_VERSION=0.4.7
SOLO_UI_OIDC_ISSUER=
SOLO_UI_BACKEND_CLIENT_ID=kagent-backend
SOLO_UI_FRONTEND_CLIENT_ID=kagent-ui
```

When `SOLO_UI_OIDC_ISSUER` is blank, the management chart enables its built-in
demo auto-auth IdP. To use a real IdP instead, set `SOLO_UI_OIDC_ISSUER` and
`SOLO_UI_BACKEND_CLIENT_SECRET`.

Deploy:

```bash
./deploy.sh
```

Open the UI:

```bash
kubectl port-forward -n agentgateway-system svc/solo-enterprise-ui 8090:80
open http://localhost:8090
```

To skip the UI entirely, set `ENABLE_AGENTGATEWAY_UI=false`.

The deploy script also applies `manifests/agentgateway-tracing.yaml`, which
configures agentgateway to send OTLP traces directly to the Solo UI telemetry
collector service. This is the UI-native tracing path; it does not require
Prometheus scraping.

## Enterprise Features Covered

The intense suite exercises these Enterprise agentgateway capabilities:

- `EnterpriseAgentgatewayPolicy` promptGuard request webhooks
- promptGuard response webhooks
- `failureMode: FailClosed`
- OpenAI-compatible backend routing
- F5 inline routing through an `AgentgatewayBackend`
- Solo/kagent Enterprise UI deployment for agentgateway visibility and workflows

The suite does not create an MCP elicitation backend by default. That keeps this
demo focused on LLM guardrails. agentgateway token exchange and elicitation
flows require issuer/STS configuration in `v2026.6.3`; add those as a separate
MCP-focused extension when you want to test them.
