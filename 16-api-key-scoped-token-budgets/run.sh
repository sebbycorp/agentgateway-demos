#!/usr/bin/env bash
# Thin alias so the demo starts with either ./setup.sh or ./run.sh.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/setup.sh" "$@"
