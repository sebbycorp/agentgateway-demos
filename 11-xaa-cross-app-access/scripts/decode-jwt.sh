#!/usr/bin/env bash
# decode-jwt.sh — Pretty-print JWT header + payload (no signature verify).
# Usage: ./scripts/decode-jwt.sh <jwt>   or   echo "$JWT" | ./scripts/decode-jwt.sh
set -euo pipefail

JWT="${1:-}"
if [[ -z "$JWT" && ! -t 0 ]]; then
  JWT="$(cat)"
fi
JWT="$(echo -n "$JWT" | tr -d '\n\r ')"
if [[ -z "$JWT" ]]; then
  echo "Usage: $0 <jwt>" >&2
  exit 1
fi

b64url_decode() {
  local raw="$1"
  local mod=$(( ${#raw} % 4 ))
  if [[ $mod -eq 2 ]]; then raw="${raw}=="
  elif [[ $mod -eq 3 ]]; then raw="${raw}="
  elif [[ $mod -eq 1 ]]; then raw="${raw}==="
  fi
  echo -n "$raw" | tr '_-' '/+' | base64 -d 2>/dev/null
}

IFS='.' read -r H P _S <<<"$JWT"
if [[ -z "${H:-}" || -z "${P:-}" ]]; then
  echo "Not a JWT (expected three base64url segments)" >&2
  exit 1
fi

echo "=== header ==="
b64url_decode "$H" | jq . 2>/dev/null || b64url_decode "$H"
echo "=== payload ==="
b64url_decode "$P" | jq . 2>/dev/null || b64url_decode "$P"
echo "=== signature ==="
echo "(present, not verified)"
