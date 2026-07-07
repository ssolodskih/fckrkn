#!/usr/bin/env bash
# Deploy the yacfsocks relay to a plain Yandex Cloud Function.
# Requires: yc CLI (authenticated), zip.
#
#   TOKEN=$(openssl rand -hex 16) ./deploy.sh
#
# Prints the public FUNCTION_URL and the TOKEN to use in the client.
set -euo pipefail

FUNC_NAME="${FUNC_NAME:-yacfsocks}"
RUNTIME="${RUNTIME:-python312}"
MEMORY="${MEMORY:-256m}"
TIMEOUT="${TIMEOUT:-60s}"
CONCURRENCY="${CONCURRENCY:-16}"
PROVISIONED="${PROVISIONED:-1}"   # always-warm instances (holds SESSIONS state)
TOKEN="${TOKEN:-$(openssl rand -hex 16)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ZIP="$(mktemp -d)/func.zip"
( cd "$HERE/function" && zip -q -r "$ZIP" handler.py requirements.txt )

# Create the function only if it doesn't exist yet (surface real create errors).
if ! yc serverless function get --name "$FUNC_NAME" >/dev/null 2>&1; then
  echo "Creating function $FUNC_NAME..."
  yc serverless function create --name "$FUNC_NAME"
fi

echo "Deploying version..."
yc serverless function version create \
  --function-name "$FUNC_NAME" \
  --runtime "$RUNTIME" \
  --entrypoint handler.handler \
  --memory "$MEMORY" \
  --execution-timeout "$TIMEOUT" \
  --concurrency "$CONCURRENCY" \
  --source-path "$ZIP" \
  --environment "TOKEN=$TOKEN,EXCHANGE_WAIT=0.5"

# Keep one always-warm instance and cap the zone to a single instance, so every
# session's calls hit the one process that holds the SESSIONS socket state.
# ('--min-instances' is not a version-create flag; warm instances are a scaling policy.)
yc serverless function set-scaling-policy "$FUNC_NAME" \
  --tag '$latest' \
  --provisioned-instances-count "$PROVISIONED" \
  --zone-instances-limit 1

# Make it publicly invocable (the client is unauthenticated at the IAM layer;
# access is gated by TOKEN in the request body).
yc serverless function allow-unauthenticated-invoke "$FUNC_NAME"

FUNC_ID="$(yc serverless function get --name "$FUNC_NAME" --format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
URL="https://functions.yandexcloud.net/${FUNC_ID}"

echo
echo "Deployed. Configure the client with:"
echo "  export FUNCTION_URL=$URL"
echo "  export TOKEN=$TOKEN"
echo "  python client/client.py"
