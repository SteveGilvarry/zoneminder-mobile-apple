#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$ROOT/api/openapi/zoneminder.openapi.json"
OUT="$ROOT/api/generated/swift"

if ! command -v swift-openapi-generator >/dev/null 2>&1; then
  echo "swift-openapi-generator is required. Install it, then rerun this script." >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
swift-openapi-generator generate "$SPEC" --output-directory "$OUT"
echo "Generated Swift client into $OUT"
