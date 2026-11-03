#!/bin/sh
# Usage: scripts/import_pipelines.sh
# Creates every pipeline in pipelines/ in the target Harness project.
# Env: HARNESS_API_KEY, HARNESS_ACCOUNT_ID, HARNESS_ORG, HARNESS_PROJECT
# The YAML files carry orgIdentifier/projectIdentifier; they are rewritten to the target org/project on the fly.
set -eu

: "${HARNESS_API_KEY:?set HARNESS_API_KEY}" "${HARNESS_ACCOUNT_ID:?set HARNESS_ACCOUNT_ID}"
org=${HARNESS_ORG:?set HARNESS_ORG}
project=${HARNESS_PROJECT:?set HARNESS_PROJECT}
base=${HARNESS_BASE_URL:-https://app.harness.io}
dir=$(cd "$(dirname "$0")/.." && pwd)

for f in "$dir"/pipelines/*.yaml; do
  body=$(sed -e "s/^  orgIdentifier: .*/  orgIdentifier: ${org}/" -e "s/^  projectIdentifier: .*/  projectIdentifier: ${project}/" "$f")
  code=$(printf '%s\n' "$body" | curl -sS -o /tmp/import_out.json -w '%{http_code}' -X POST \
    "${base}/pipeline/api/pipelines/v2?accountIdentifier=${HARNESS_ACCOUNT_ID}&orgIdentifier=${org}&projectIdentifier=${project}" \
    -H "x-api-key: ${HARNESS_API_KEY}" -H "Content-Type: application/yaml" --data-binary @-)
  echo "$(basename "$f") -> HTTP ${code}"
  [ "$code" -lt 300 ] || jq -r '.message // .' /tmp/import_out.json
done
