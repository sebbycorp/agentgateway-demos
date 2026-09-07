# Repo-root build context (Railway /railway.toml, or `docker build .`).
# Canonical comments live in deploy/Dockerfile. Keep the two files in sync
# except for COPY paths.

FROM golang:1.22-bookworm AS build
WORKDIR /src
COPY deploy/go.mod deploy/go.sum deploy/entrypoint.go ./
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
RUN node -v && npx --version && /app/agentgateway --version
USER 0
EXPOSE 4000
ENTRYPOINT ["/entrypoint"]
