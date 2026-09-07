# PaaS image: static entrypoint (htpasswd + seed config) then official v1.5.0.
# The published image has no shell (ENTRYPOINT=/app/agentgateway), so we cannot
# generate /config/.htpasswd from a shell script inside that image alone.
#
# Pin: https://agentgateway.dev/docs/standalone/latest/setup/install/docker/
#
# The published image USER is 65532. PaaS volumes are typically root-owned,
# so first boot cannot write /config unless we run as root.

FROM golang:1.22-bookworm AS build
WORKDIR /src
COPY go.mod go.sum entrypoint.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /entrypoint entrypoint.go

FROM cr.agentgateway.dev/agentgateway:v1.5.0
USER 0
COPY --from=build /entrypoint /entrypoint
EXPOSE 4000
ENTRYPOINT ["/entrypoint"]
