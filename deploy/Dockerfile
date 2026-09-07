# PaaS image: static entrypoint (htpasswd + seed config) then official v1.5.0
# plus Node/npx so stdio MCP targets can run
# (`@modelcontextprotocol/server-everything`, `@modelcontextprotocol/server-github`).
#
# The published image has no shell and no Node (ENTRYPOINT=/app/agentgateway).
# Mixing a Node tree into that Chainguard/distroless image is fragile: npx is a
# #!/usr/bin/env shebang, and Node needs libstdc++ the gateway image may not
# ship. Final stage is Debian so shebangs and glibc deps work; the gateway
# binary is copied from the official image.
#
# v1.5.0 is built on rust:trixie (GNU glibc). debian:bookworm-slim's older
# glibc can reject that binary, so the runtime is trixie-slim.
#
# Pin: https://agentgateway.dev/docs/standalone/latest/setup/install/docker/
#
# The published image USER is 65532. PaaS volumes are typically root-owned,
# so first boot cannot write /config unless we run as root.

FROM golang:1.22-bookworm AS build
WORKDIR /src
COPY go.mod go.sum entrypoint.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /entrypoint entrypoint.go

FROM cr.agentgateway.dev/agentgateway:v1.5.0 AS agw

FROM node:22-bookworm-slim AS node

FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local /usr/local
COPY --from=agw /app/agentgateway /app/agentgateway
COPY --from=build /entrypoint /entrypoint
ENV PATH="/usr/local/bin:${PATH}" \
    NPM_CONFIG_CACHE=/tmp/.npm \
    npm_config_cache=/tmp/.npm \
    HOME=/tmp
# Fail the image build if Node/npx or the gateway binary cannot run (glibc).
RUN node -v && npx --version && /app/agentgateway --version
USER 0
EXPOSE 4000
ENTRYPOINT ["/entrypoint"]
