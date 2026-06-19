#!/bin/bash
set -e

VERSION=5
REGISTRY=${REGISTRY:-csakaszamok/foxglove}

DIND_IMAGE="${REGISTRY}:${VERSION}-dind"
SYSBOX_IMAGE="${REGISTRY}:${VERSION}-sysbox"

echo "==> Building DinD image: $DIND_IMAGE"
docker build -t "$DIND_IMAGE" -f Dockerfile.dind .

echo "==> Building Sysbox image: $SYSBOX_IMAGE"
docker build -t "$SYSBOX_IMAGE" -f Dockerfile.sysbox .

echo "==> Pushing $DIND_IMAGE"
docker push "$DIND_IMAGE"

echo "==> Pushing $SYSBOX_IMAGE"
docker push "$SYSBOX_IMAGE"
