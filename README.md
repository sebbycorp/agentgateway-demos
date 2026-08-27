# agentgateway-demos

Self-contained [AgentGateway](https://agentgateway.dev) demos. Each numbered directory is independent.

| Dir | Mode | What it shows |
|-----|------|----------------|
| [`00-standalone-latest`](./00-standalone-latest) | Standalone Docker | Cost / analytics dashboard + SQLite |
| [`02-standalone-docker`](./02-standalone-docker) | Standalone Docker | Minimal LLM proxy config |
| [`04-vitural-keys`](./04-vitural-keys) | Kubernetes | Virtual keys via Redis / Envoy rate limits (older approach) |
| [`08-standalone-langfuse`](./08-standalone-langfuse) | Standalone | OTLP traces to Langfuse |
| [`11-xaa-cross-app-access`](./11-xaa-cross-app-access) | Standalone | XAA / EMA / ID-JAG + Keycloak |
| [`15-github-copilot`](./15-github-copilot) | Standalone | GitHub Copilot MCP |
| [`16-api-key-scoped-token-budgets`](./16-api-key-scoped-token-budgets) | Standalone Docker | **v1.5.0 API-key-scoped token budgets** |

See each folder's README for start / test / teardown. Conventions live in [`CLAUDE.md`](./CLAUDE.md).
