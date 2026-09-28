#!/bin/bash
set -e

VERSION=$(cat "$(dirname "$0")/VERSION")
REGISTRY=${REGISTRY:-csakaszamok/foxglove}

DIND_IMAGE="${REGISTRY}:${VERSION}-dind"
DIND_LATEST="${REGISTRY}:latest-dind"
SYSBOX_IMAGE="${REGISTRY}:${VERSION}-sysbox"
SYSBOX_LATEST="${REGISTRY}:latest-sysbox"

echo "==> Building DinD image: $DIND_IMAGE"
docker build -t "$DIND_IMAGE" -t "$DIND_LATEST" -f Dockerfile.dind .

echo "==> Building Sysbox image: $SYSBOX_IMAGE"
docker build -t "$SYSBOX_IMAGE" -t "$SYSBOX_LATEST" -f Dockerfile.sysbox .

echo "==> Pushing $DIND_IMAGE"
docker push "$DIND_IMAGE"
docker push "$DIND_LATEST"

echo "==> Pushing $SYSBOX_IMAGE"
docker push "$SYSBOX_IMAGE"
docker push "$SYSBOX_LATEST"
