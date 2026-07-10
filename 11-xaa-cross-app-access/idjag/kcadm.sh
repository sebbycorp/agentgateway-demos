#!/usr/bin/env bash
# Run Keycloak's admin CLI INSIDE the running ID-JAG container, so no host
# Keycloak install is needed. Used as the KCADM for setup.sh / setup-leg2.sh.
#   KC_CONTAINER  container name (default: agw-xaa-kc-idjag)
exec docker exec -i "${KC_CONTAINER:-agw-xaa-kc-idjag}" /opt/keycloak/bin/kcadm.sh "$@"
