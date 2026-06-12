---
name: agentgateway
description: >
  Learn about, understand, deploy, develop, and contribute to Agentgateway — the Linux Foundation open-source agentic proxy and AI gateway for MCP & A2A protocols. Covers architecture, LLM routing, MCP gateway, A2A gateway, guardrails, security, observability, standalone & Kubernetes deployment, UI, development, and contributing. Trigger phrases: "agentgateway", "agw", "agent gateway", "agentic proxy", MCP gateway, A2A gateway, LLM proxy, AI gateway, agentgateway.dev, @https://github.com/agentgateway/agentgateway. Use when the user runs /agentgateway.
---

# Agentgateway Skill

Agentgateway is the first complete connectivity solution for Agentic AI. It is an open-source proxy built on AI-native protocols (MCP & A2A) that provides security, observability, and governance for agent-to-LLM, agent-to-tool, and agent-to-agent communication.

## Key Features

- **LLM Gateway** — Route traffic to major LLM providers (OpenAI, Anthropic, Gemini, Bedrock) through a unified OpenAI-compatible API with budget controls, prompt enrichment, load balancing, and failover.
- **MCP Gateway** — Connect LLMs to tools and external data sources via MCP with tool federation, stdio/HTTP/SSE/Streamable HTTP transports, OpenAPI integration, and OAuth authentication.
- **A2A Gateway** — Enable secure agent-to-agent communication using A2A protocol with capability discovery, modality negotiation, and task collaboration.
- **Inference Routing** — Intelligent routing to self-hosted models using Kubernetes Inference Gateway extensions (GPU utilization, KV cache, LoRA adapters, queue depth).
- **Guardrails** — Multi-layered content filtering: regex, OpenAI moderation, AWS Bedrock Guardrails, Google Model Armor, custom webhooks.
- **Security & Observability** — Auth (JWT, API keys, OAuth), fine-grained RBAC with CEL policy engine, rate limiting, TLS, OpenTelemetry metrics/logs/tracing.

## Repository

- **Code:** https://github.com/agentgateway/agentgateway
- **Docs (standalone):** https://agentgateway.dev/docs/
- **Docs (Kubernetes):** https://agentgateway.dev/docs/kubernetes/latest
- **Quickstart (standalone):** https://agentgateway.dev/docs/quickstart
- **Quickstart (Kubernetes):** https://agentgateway.dev/docs/kubernetes/latest
- **Discord:** https://discord.gg/BdJpzaPjHv
- **License:** Apache 2.0
- **Latest release:** https://github.com/agentgateway/agentgateway/releases

## Architecture

Agentgateway is written in Rust (~62%) with Go (~26%) for the controller and TypeScript (~9%) for the UI. The repository structure:

```
agentgateway/
├── api/            # Protobuf/API definitions
├── architecture/   # Architecture docs
├── controller/     # Kubernetes controller (Go)
├── crates/         # Rust crates (core dataplane)
├── design/         # Design documents
├── examples/       # Usage examples
├── manifests/      # K8s manifests/Helm charts
├── schema/         # JSON Schema / OpenAPI
├── tools/          # CLI tools
├── ui/             # Web UI (TypeScript/React)
├── Cargo.toml      # Rust workspace
├── Makefile        # Build targets
├── Tiltfile        # Local K8s dev env
└── Dockerfile      # Container build
```

## Deployments

### Standalone (local/on-prem)

1. Download from https://agentgateway.dev/docs/quickstart
2. Run: `./target/release/agentgateway`
3. Open UI at http://localhost:15000/ui

### Kubernetes

Deploy using the built-in controller and Gateway API:
1. Follow: https://agentgateway.dev/docs/kubernetes/latest
2. Local dev: use `tilt up` with a Kind cluster

## Development

### Requirements
- Rust 1.86+
- npm 10+
- (K8s dev) Kind, Tilt, ctlptl, Docker, Go 1.22+

### Build from source
```bash
# UI
cd ui && npm install && npm run build

# Binary
cd ..
export CARGO_NET_GIT_FETCH_WITH_CLI=true
make build

# Run
./target/release/agentgateway
```

### Local K8s development
```bash
ctlptl create cluster kind --name kind-kind --registry=ctlptl-registry
tilt up
```

### Testing
```bash
cargo test --all
make lint
```

## Contributing

1. Fork the repo on GitHub
2. Clone your fork: `git clone https://github.com/YOUR-USERNAME/agentgateway.git`
3. Add upstream: `git remote add upstream https://github.com/agentgateway/agentgateway.git`
4. Create a branch: `git checkout -b feature/your-feature-name`
5. Follow [Conventional Commits](https://www.conventionalcommits.org/)
6. Before submitting: `make lint` and `cargo test --all`
7. Push and open a PR

See [CONTRIBUTION.md](https://github.com/agentgateway/agentgateway/blob/main/CONTRIBUTION.md) for full guidelines.

## Community

- **Community meetings:** Add the [agentgateway calendar](https://calendar.google.com/calendar/u/0?cid=Y18zZTAzNGE0OTFiMGUyYzU2OWI1Y2ZlOWNmOWM4NjYyZTljNTNjYzVlOTdmMjdkY2I5ZTZmNmM5ZDZhYzRkM2ZmQGdyb3VwLmNhbGVuZGFyLmdvb2dsZS5jb20) to your Google account
- **Meeting recordings:** [Google Drive](https://drive.google.com/drive/folders/138716fESpxLkbd_KkGrUHa6TD7OA2tHs?usp=sharing)
- **Discord:** https://discord.gg/BdJpzaPjHv
- **Issues/Features:** https://github.com/agentgateway/agentgateway/issues

## Common Tasks

### "How do I deploy agentgateway?"
- For quick local testing: standalone quickstart at https://agentgateway.dev/docs/quickstart
- For Kubernetes: K8s quickstart at https://agentgateway.dev/docs/kubernetes/latest

### "How do I add a new LLM provider?"
Configure in the LLM Gateway section with provider-specific API keys. Agentgateway supports OpenAI, Anthropic, Gemini, Bedrock, and custom OpenAI-compatible endpoints. Check the docs for provider configuration.

### "How do I set up MCP gateway?"
Configure MCP transports (stdio, HTTP, SSE, Streamable HTTP) to connect tools and data sources. Supports OpenAPI integration and OAuth auth. See MCP Gateway docs.

### "How do I enable guardrails?"
Configure multi-layer content filtering: regex patterns, OpenAI moderation API, AWS Bedrock Guardrails, Google Model Armor, or custom webhook endpoints.

### "How do I contribute?"
See CONTRIBUTION.md in the repo. Follow Conventional Commits, run `make lint` and `cargo test --all` before submitting PRs.
