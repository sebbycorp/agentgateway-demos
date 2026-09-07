# Thin wrapper so Railway / Fly pull the official OSS image instead of
# rebuilding agentgateway.
# Pin: https://agentgateway.dev/docs/standalone/latest/setup/install/docker/
#
# The published image USER is 65532. PaaS volumes are typically root-owned,
# so first boot cannot write /config/config.yaml unless we run as root.
FROM cr.agentgateway.dev/agentgateway:v1.5.0
USER 0
EXPOSE 4000
