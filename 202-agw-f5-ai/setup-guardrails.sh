#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
[[ -f "${SCRIPT_DIR}/../.env" ]] && source "${SCRIPT_DIR}/../.env"
[[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"
set +a

: "${F5_AISEC_URL:?F5_AISEC_URL is required}"
: "${F5_AISEC_TOKEN:?F5_AISEC_TOKEN is required}"

BASE="${F5_AISEC_URL%/}"
PROJECT="${CAI_PROJECT:-}"
INLINE_PROVIDER="${F5_AISEC_INLINE_PROVIDER:-genai-azure-openai}"

api() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "${BASE}${path}" \
      -H "Authorization: Bearer ${F5_AISEC_TOKEN}" \
      -H "content-type: application/json" \
      -d "$data"
  else
    curl -sS -X "$method" "${BASE}${path}" \
      -H "Authorization: Bearer ${F5_AISEC_TOKEN}"
  fi
}

scanner_id_by_name() {
  local name="$1"
  api GET /backend/v1/scanners | jq -r --arg name "$name" '.scanners[]? | select(.name == $name) | .id' | head -n 1
}

scanner_version_by_name() {
  local name="$1"
  api GET /backend/v1/scanners | jq -r --arg name "$name" '.scanners[]? | select(.name == $name) | .versionMeta.id' | head -n 1
}

ensure_scanner() {
  local name="$1" payload="$2"
  local scanner_id
  scanner_id="$(scanner_id_by_name "$name")"
  if [[ -z "$scanner_id" ]]; then
    scanner_id="$(api POST /backend/v1/scanners "$payload" | jq -r '.id')"
    [[ -n "$scanner_id" && "$scanner_id" != "null" ]] || { echo "Failed to create scanner '${name}'" >&2; exit 1; }
  fi
  printf '%s' "$scanner_id"
}

echo "==> Validating F5 AI Security token and tenant"
api GET /backend/v1/users/me | jq -e '.user.id // .user.email' >/dev/null

echo "==> Resolving project '${PROJECT:-<first available>}'"
PROJECTS="$(api GET /backend/v1/projects)"
if [[ -n "$PROJECT" ]]; then
  RESOLVED_PROJECT="$(printf '%s' "$PROJECTS" | jq -r --arg p "$PROJECT" '.projects[]? | select(.id == $p or .friendlyId == $p or .name == $p) | .friendlyId // .id' | head -n 1)"
else
  RESOLVED_PROJECT="$(printf '%s' "$PROJECTS" | jq -r '.projects[]? | select(.type != "global") | .friendlyId // .id' | head -n 1)"
  [[ -n "$RESOLVED_PROJECT" ]] || RESOLVED_PROJECT="$(printf '%s' "$PROJECTS" | jq -r '.projects[0].friendlyId // .projects[0].id // empty')"
fi
if [[ -z "$RESOLVED_PROJECT" ]]; then
  echo "Project '${PROJECT:-<first available>}' was not found. Create it in the F5 AI Security console or set CAI_PROJECT to an existing id/friendlyId."
  exit 1
fi
echo "    using project '${RESOLVED_PROJECT}'"

echo "==> Checking inline provider '${INLINE_PROVIDER}'"
if ! api GET "/backend/v1/providers/${INLINE_PROVIDER}" | jq . >/dev/null; then
  echo "Provider '${INLINE_PROVIDER}' was not found. Create/configure it in F5 AI Security for Option A."
  exit 1
fi

echo "==> Ensuring demo scanners"
KEYWORD_PAYLOAD="$(jq -nc '{
  name: "agw-lab-keyword-codename",
  config: {words: ["project-titan"], type: "keyword"},
  direction: "both",
  global: true,
  published: true,
  version: {name: "v1", description: "Block project-titan demo codename", published: true}
}')"
SSN_PAYLOAD="$(jq -nc '{
  name: "agw-lab-regex-ssn",
  config: {pattern: "\\d{3}-\\d{2}-\\d{4}", type: "regex"},
  direction: "request",
  global: true,
  published: true,
  version: {name: "v1", description: "Redact SSN demo pattern", published: true}
}')"
KEYWORD_ID="$(ensure_scanner agw-lab-keyword-codename "$KEYWORD_PAYLOAD")"
SSN_ID="$(ensure_scanner agw-lab-regex-ssn "$SSN_PAYLOAD")"
KEYWORD_VERSION="$(scanner_version_by_name agw-lab-keyword-codename)"
SSN_VERSION="$(scanner_version_by_name agw-lab-regex-ssn)"

PROJECT_ID="$(printf '%s' "$PROJECTS" | jq -r --arg p "$RESOLVED_PROJECT" '.projects[]? | select(.id == $p or .friendlyId == $p or .name == $p) | .id' | head -n 1)"
for scanner_id in "$KEYWORD_ID" "$SSN_ID"; do
  api POST "/backend/v1/projects/${PROJECT_ID}/scanners/${scanner_id}" '{}' >/dev/null || true
done

PATCH_PAYLOAD="$(jq -nc \
  --arg keyword_id "$KEYWORD_ID" \
  --arg keyword_version "$KEYWORD_VERSION" \
  --arg ssn_id "$SSN_ID" \
  --arg ssn_version "$SSN_VERSION" \
  '{
    config: {
      scanners: [
        {id: $keyword_id, version: $keyword_version, enabled: true, blocking: true, force: false, mode: "block", flagMessage: "Blocked by AGW/F5 lab scanner"},
        {id: $ssn_id, version: $ssn_version, enabled: true, blocking: false, force: false, mode: "redact", flagMessage: "Redacted by AGW/F5 lab scanner"}
      ]
    },
    deploymentStatus: "live"
  }')"
api PATCH "/backend/v1/projects/${PROJECT_ID}" "$PATCH_PAYLOAD" | jq -e '.message == "Project updated"' >/dev/null

echo "==> Checking ScanAPI against project '${RESOLVED_PROJECT}'"
api POST /backend/v1/scans "$(jq -nc --arg project "$RESOLVED_PROJECT" '{input:"hello",project:$project,scanDirection:"request",flagOnly:false,verbose:true}')" \
  | jq -e '.result.outcome' >/dev/null
api POST /backend/v1/scans "$(jq -nc --arg project "$RESOLVED_PROJECT" '{input:"Tell me about project-titan",project:$project,scanDirection:"request",flagOnly:false,verbose:true}')" \
  | jq -e '.result.outcome == "blocked"' >/dev/null
api POST /backend/v1/scans "$(jq -nc --arg project "$RESOLVED_PROJECT" '{input:"my ssn is 123-45-6789",project:$project,scanDirection:"request",flagOnly:false,verbose:true}')" \
  | jq -e '.result.outcome == "redacted" and (.redactedInput | contains("123-45-6789") | not)' >/dev/null

echo "F5 AI Security tenant checks passed."
