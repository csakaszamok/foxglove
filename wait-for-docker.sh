#!/bin/sh
# Wait until the Docker daemon actually answers on its socket. Checking only
# that the socket file exists is not enough: after an abrupt kill (SIGKILL)
# a stale socket is left in the container's writable layer.
SOCKET=${DOCKER_SOCK:-/var/run/docker.sock}
TIMEOUT=${TIMEOUT:-60}
INTERVAL=${INTERVAL:-2}
elapsed=0

daemon_ready() {
    if command -v docker >/dev/null 2>&1; then
        docker -H "unix://$SOCKET" version >/dev/null 2>&1
    else
        curl -fsS --unix-socket "$SOCKET" http://localhost/_ping >/dev/null 2>&1
    fi
}

echo "Waiting for Docker daemon at $SOCKET..."
while ! daemon_ready; do
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo "ERROR: Docker daemon not responding at $SOCKET after ${TIMEOUT}s" >&2
        exit 1
    fi
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done
echo "Docker daemon ready"
