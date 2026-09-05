#!/usr/bin/env bash
# Tear down the container started by run.sh / the README docker run.
set -euo pipefail
CONTAINER="${CONTAINER:-agw-cel-block-curl}"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
echo "Removed ${CONTAINER}."
