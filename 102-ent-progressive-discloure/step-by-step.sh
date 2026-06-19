#!/usr/bin/env bash
# Annotated walkthrough of deploy.sh for live demos. Pauses between phases.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run() { echo; echo "+ $*"; read -rp "  [enter to run] "; eval "$*"; }

run "kind get clusters | grep agw-progressive-disclosure || echo 'will be created'"
echo "Now running the full deploy. Each phase is described in deploy.sh."
run "${SCRIPT_DIR}/deploy.sh"
echo "Compare advertised tool counts (the whole point):"
run "echo 'default exposes all tools; search exposes only get_tool + invoke_tool'"
run "${SCRIPT_DIR}/test.sh"
echo "Open Grafana to see the savings curve: http://localhost:3001 (admin/admin)"
