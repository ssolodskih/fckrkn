#!/usr/bin/env bash
# Deploy the yacfsocks relay to a Yandex Serverless Container.
# Requires: yc CLI (authenticated), docker, openssl, uv.
#
#   TOKEN=$(openssl rand -hex 16) ./deploy-container.sh
#
# Same wire protocol as the Cloud Function (deploy.sh) - the client is unchanged,
# only FUNCTION_URL points at the container. Prints FUNCTION_URL and TOKEN.
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-yacfsocks}"
REGISTRY_NAME="${REGISTRY_NAME:-yacfsocks}"
SA_NAME="${SA_NAME:-yacfsocks}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
MEMORY="${MEMORY:-256m}"
CORES="${CORES:-1}"
TIMEOUT="${TIMEOUT:-60s}"
CONCURRENCY="${CONCURRENCY:-16}"
MIN_INSTANCES="${MIN_INSTANCES:-1}"      # always-warm instances (avoid mid-session cold starts)
ZONE_LIMIT="${ZONE_LIMIT:-1}"            # cap each zone to 1 instance (like the function)
TOKEN="${TOKEN:-$(openssl rand -hex 16)}"

HERE="$(cd "$(dirname "$0")" && pwd)"

# Extract a top-level field from `yc ... --format json` on stdin.
json_field() { uv run --project "$HERE" python -c "import sys,json;print(json.load(sys.stdin)[\"$1\"])"; }

# 1. Container Registry (create if missing), then auth docker to cr.yandex.
if ! yc container registry get --name "$REGISTRY_NAME" >/dev/null 2>&1; then
  echo "Creating container registry $REGISTRY_NAME..."
  yc container registry create --name "$REGISTRY_NAME" >/dev/null
fi
REGISTRY_ID="$(yc container registry get --name "$REGISTRY_NAME" --format json | json_field id)"
yc container registry configure-docker >/dev/null

# 2. Build and push the image. Must be linux/amd64 - YC runs amd64, so an arm64
# build (e.g. on Apple Silicon) fails at runtime with "exec format error".
IMAGE="cr.yandex/${REGISTRY_ID}/${CONTAINER_NAME}:${IMAGE_TAG}"
echo "Building and pushing $IMAGE..."
docker build --platform linux/amd64 -t "$IMAGE" "$HERE/function"
docker push "$IMAGE"

# 3. Service account the container runs as (needs to pull the image from cr.yandex).
if ! yc iam service-account get --name "$SA_NAME" >/dev/null 2>&1; then
  echo "Creating service account $SA_NAME..."
  yc iam service-account create --name "$SA_NAME" >/dev/null
fi
SA_ID="$(yc iam service-account get --name "$SA_NAME" --format json | json_field id)"
FOLDER_ID="$(yc config get folder-id)"
yc resource-manager folder add-access-binding "$FOLDER_ID" \
  --role container-registry.images.puller --subject "serviceAccount:$SA_ID" >/dev/null 2>&1 || true

# 4. Create the container only if it doesn't exist yet (surface real create errors).
if ! yc serverless container get --name "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "Creating container $CONTAINER_NAME..."
  yc serverless container create --name "$CONTAINER_NAME"
fi

# 5. Deploy a new revision. Same per-instance concurrency and TOKEN/EXCHANGE_WAIT
# env as the function; --min-instances keeps warm instances, --zone-instances-limit
# caps each zone so a session's keep-alive-pinned calls stay on one instance.
echo "Deploying revision..."
yc serverless container revision deploy \
  --container-name "$CONTAINER_NAME" \
  --image "$IMAGE" \
  --service-account-id "$SA_ID" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --execution-timeout "$TIMEOUT" \
  --concurrency "$CONCURRENCY" \
  --min-instances "$MIN_INSTANCES" \
  --zone-instances-limit "$ZONE_LIMIT" \
  --environment "TOKEN=$TOKEN,EXCHANGE_WAIT=0.5"

# 6. Make it publicly invocable (access is gated by TOKEN in the body, not IAM).
yc serverless container allow-unauthenticated-invoke --name "$CONTAINER_NAME"

URL="$(yc serverless container get --name "$CONTAINER_NAME" --format json | json_field url)"

echo
echo "Deployed. Configure the client with:"
echo "  export FUNCTION_URL=$URL"
echo "  export TOKEN=$TOKEN"
echo "  uv run client/client.py"
