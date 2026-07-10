#!/usr/bin/env bash
#
# One-shot Keycloak configuration for the ID-JAG demo: runs setup.sh (realm, user,
# the two clients / leg 1) then setup-leg2.sh (self-IdP, consumer config, federated
# link, scopes). Requires the ID-JAG Keycloak already running (see deploy.sh).
#
# Uses kcadm.sh inside the container, so no host Keycloak install is required.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export KCADM="${KCADM:-$DIR/kcadm.sh}"
export SERVER="${SERVER:-http://localhost:8480}"

"$DIR/setup.sh"
"$DIR/setup-leg2.sh"

echo
echo "Keycloak configured:"
echo "  realm          : idjag-demo"
echo "  user           : alice / alice"
echo "  agent-client   : agent-secret     (requesting app; mints ID-JAG via token exchange)"
echo "  resource-client: resource-secret  (resource AS; consumes ID-JAG via jwt-bearer)"
echo "  IdP            : self-idjag       (self-referential JWT_AUTHORIZATION_GRANT)"
