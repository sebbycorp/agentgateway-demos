# agentgateway-demos

Hands-on demos for [Enterprise Agentgateway](https://docs.solo.io/agentgateway/) running on a local Kind cluster.

## Demos

### Microsoft Entra ID OBO Token Exchange

Demonstrates the Entra On-Behalf-Of (OBO) token exchange flow where the gateway automatically exchanges a user's Entra token for a downstream API token — without the user needing to authenticate to each backend service directly.

- [Full documentation and concepts](docs/entra-obo-token-exchange.md)

## Quick Start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [jq](https://jqlang.github.io/jq/download/)
- A Solo trial license key (`SOLO_TRIAL_LICENSE_KEY`)

### 1. Create the Kind Cluster

```bash
export SOLO_TRIAL_LICENSE_KEY="<your-license-key>"
./scripts/setup-kind.sh
```

### 2. Run a Demo

#### Entra OBO Token Exchange

```bash
# Set Azure env vars
export ENTRA_TENANT_ID="<your-tenant-id>"
export ENTRA_MIDDLETIER_CLIENT_ID="<your-middle-tier-client-id>"
export ENTRA_DOWNSTREAM_SCOPE="api://<your-downstream-app-id>/.default"
export ENTRA_OBO_CLIENT_SECRET="<your-client-secret>"

# Deploy
./scripts/deploy-entra-obo.sh

# Test
az login
./scripts/test-entra-obo.sh

# Cleanup
./scripts/cleanup-entra-obo.sh
```

### Tear Down

```bash
kind delete cluster --name agentgateway-demo
```

## Repository Structure

```
.
├── README.md
├── docs/
│   └── entra-obo-token-exchange.md   # Concepts + walkthrough
├── scripts/
│   ├── setup-kind.sh                  # Kind cluster + AGW install
│   ├── deploy-entra-obo.sh           # Deploy Entra OBO demo
│   ├── test-entra-obo.sh             # Test the OBO exchange
│   └── cleanup-entra-obo.sh          # Remove demo resources
└── manifests/                         # (reserved for future demos)
```
