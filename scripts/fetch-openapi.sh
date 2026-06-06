#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="${ZM_OPENAPI_URL:-http://zoneminder.local:8080/api-docs/openapi.json}"
mkdir -p "$ROOT/api/openapi"
curl -fsS --max-time 20 "$URL" -o "$ROOT/api/openapi/zoneminder.openapi.json"
echo "Fetched $URL"
