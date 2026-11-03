#!/bin/sh
# Usage: scripts/run_pipeline.sh <pipeline_identifier> <inputs.yaml>
# Env: HARNESS_API_KEY, HARNESS_ACCOUNT_ID, HARNESS_ORG, HARNESS_PROJECT
set -eu

pipeline=${1:?pipeline identifier required}
inputs=${2:?runtime inputs YAML file required}
: "${HARNESS_API_KEY:?set HARNESS_API_KEY}" "${HARNESS_ACCOUNT_ID:?set HARNESS_ACCOUNT_ID}"
org=${HARNESS_ORG:?set HARNESS_ORG}
project=${HARNESS_PROJECT:?set HARNESS_PROJECT}
base=${HARNESS_BASE_URL:-https://app.harness.io}

code=$(curl -sS -o /tmp/run_out.json -w '%{http_code}' -X POST \
  "${base}/pipeline/api/pipeline/execute/${pipeline}?accountIdentifier=${HARNESS_ACCOUNT_ID}&orgIdentifier=${org}&projectIdentifier=${project}&moduleType=ci" \
  -H "x-api-key: ${HARNESS_API_KEY}" \
  -H "Content-Type: application/yaml" \
  --data-binary "@${inputs}")

if [ "$code" -ge 300 ]; then
  echo "Execution request failed with HTTP ${code}" >&2
  jq . /tmp/run_out.json >&2 || cat /tmp/run_out.json >&2
  exit 1
fi

id=$(jq -r '.data.planExecution.uuid' /tmp/run_out.json)
echo "Started ${pipeline}: execution ${id}"
echo "${base}/ng/account/${HARNESS_ACCOUNT_ID}/all/orgs/${org}/projects/${project}/pipelines/${pipeline}/deployments/${id}/pipeline"
