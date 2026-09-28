#!/bin/sh
# Remove Docker runtime files left behind by an abrupt kill (SIGKILL, power
# loss). /var/run lives in the container's writable layer, so they survive a
# restart: a stale docker.sock fools socket-existence checks, and stale pid
# files can point at a reused PID and block dockerd/containerd from starting.
RUN_DIR=${DOCKER_RUN_DIR:-/var/run}

if ! pgrep -x dockerd >/dev/null 2>&1; then
    for f in "$RUN_DIR/docker.sock" "$RUN_DIR/docker.pid"; do
        if [ -e "$f" ]; then
            echo "Removing stale $f"
            rm -f "$f"
        fi
    done
fi

if ! pgrep -x containerd >/dev/null 2>&1; then
    f="$RUN_DIR/docker/containerd/containerd.pid"
    if [ -e "$f" ]; then
        echo "Removing stale $f"
        rm -f "$f"
    fi
fi
exit 0
