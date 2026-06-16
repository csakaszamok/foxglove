#!/bin/sh
SOCKET=${DOCKER_SOCK:-/var/run/docker.sock}
TIMEOUT=${TIMEOUT:-60}
INTERVAL=${INTERVAL:-2}
elapsed=0

echo "Waiting for Docker socket at $SOCKET..."
while [ ! -S "$SOCKET" ]; do
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo "ERROR: Docker socket not available at $SOCKET after ${TIMEOUT}s" >&2
        exit 1
    fi
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done
echo "Docker socket ready"
