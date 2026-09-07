# Repo-root build context (Railway /railway.toml, or `docker build .`).
# Canonical comments live in deploy/Dockerfile. Keep the two files in sync
# except for COPY paths.

FROM golang:1.22-bookworm AS build
WORKDIR /src
COPY deploy/go.mod deploy/go.sum deploy/entrypoint.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /entrypoint entrypoint.go

FROM cr.agentgateway.dev/agentgateway:v1.5.0
USER 0
COPY --from=build /entrypoint /entrypoint
EXPOSE 4000
ENTRYPOINT ["/entrypoint"]
