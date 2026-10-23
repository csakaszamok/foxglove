#!/bin/bash
# Integration test: after an abrupt kill (SIGKILL, exit 137) the restarted
# foxglove container must regenerate frpc.toml with proxies for the inner
# containers, and the app must be reachable through frps again.
# Also verifies the graceful docker stop / docker start cycle.
#
# Runs against the host Docker daemon. Usage:
#   IMAGE=ghcr.io/p7y-dev/foxglove:0.8.0-dind bash tests/test-sigkill-recovery.sh
#   IMAGE=ghcr.io/p7y-dev/foxglove:0.8.0-sysbox RUN_OPTS="--runtime=sysbox-runc" bash tests/test-sigkill-recovery.sh
set -u
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: don't rewrite /etc/... args

IMAGE=${IMAGE:?set IMAGE to the foxglove image under test}
RUN_OPTS=${RUN_OPTS:---privileged}
INNER_IMAGE=${INNER_IMAGE:-nginx:alpine}
FRPS_IMAGE=${FRPS_IMAGE:-fatedier/frps:v0.62.1}
RECOVERY_TIMEOUT=${RECOVERY_TIMEOUT:-45}

P=fgtest-$$
NET=$P-net
FRPS=$P-frps
FOX=$P-fox
INSTANCE=fgtest
DOMAIN=test.local
TOKEN=test-token
PROXY_HOST=$INSTANCE-web-port8080.$DOMAIN

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

cleanup() {
    docker rm -f "$FOX" "$FRPS" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT

has_proxies() { docker exec "$FOX" grep -q '^\[\[proxies\]\]' /etc/frpc/frpc.toml 2>/dev/null; }

app_reachable() {
    docker run --rm --network "$NET" --entrypoint wget "$IMAGE" \
        -q -T 3 -O /dev/null --header "Host: $PROXY_HOST" "http://$FRPS:8080/" >/dev/null 2>&1
}

# wait_for <seconds> <command...>: poll once per second; prints elapsed seconds
wait_for() {
    local timeout=$1; shift
    local t=0
    while [ "$t" -lt "$timeout" ]; do
        if "$@"; then echo "$t"; return 0; fi
        sleep 1
        t=$((t + 1))
    done
    return 1
}

check_recovered() {
    local label=$1 t
    if t=$(wait_for "$RECOVERY_TIMEOUT" has_proxies); then
        pass "$label: frpc.toml has [[proxies]] after ${t}s"
    else
        fail "$label: frpc.toml has no [[proxies]] after ${RECOVERY_TIMEOUT}s"
        docker exec "$FOX" cat /etc/frpc/frpc.toml
        docker logs "$FOX" 2>&1 | grep -iE 'docker-gen|docker endpoint|Watching|Generated|socket|daemon' | tail -15
    fi
    if t=$(wait_for "$RECOVERY_TIMEOUT" app_reachable); then
        pass "$label: app reachable through frps after ${t}s"
    else
        fail "$label: app not reachable through frps after ${RECOVERY_TIMEOUT}s"
    fi
}

echo "==> Image under test: $IMAGE ($RUN_OPTS)"
docker network create "$NET" >/dev/null
docker run -d --name "$FRPS" --network "$NET" "$FRPS_IMAGE" \
    -t "$TOKEN" --vhost-http-port 8080 >/dev/null

# shellcheck disable=SC2086
docker create --name "$FOX" --network "$NET" $RUN_OPTS \
    -e FRP_SERVER_ADDR="$FRPS" -e FRP_SERVER_PORT=7000 \
    -e FRP_TOKEN="$TOKEN" -e BASE_DOMAIN="$DOMAIN" \
    "$IMAGE" >/dev/null
d=$(mktemp -d)
echo "$INSTANCE" > "$d/name"
src=$d; command -v cygpath >/dev/null && src=$(cygpath -w "$d")
docker cp "$src/." "$FOX:/etc/instance" >/dev/null
rm -rf "$d"
docker start "$FOX" >/dev/null

if ! wait_for 60 docker exec "$FOX" docker info >/dev/null 2>&1; then
    fail "inner dockerd did not come up"; exit 1
fi
docker save "$INNER_IMAGE" | docker exec -i "$FOX" docker load >/dev/null
docker exec "$FOX" docker run -d --name web --restart unless-stopped -p 8080:80 "$INNER_IMAGE" >/dev/null
check_recovered "initial start"

echo "==> docker kill -s KILL + docker start"
docker kill -s KILL "$FOX" >/dev/null
docker start "$FOX" >/dev/null
check_recovered "after SIGKILL"

echo "==> docker stop + docker start"
docker stop "$FOX" >/dev/null
docker start "$FOX" >/dev/null
check_recovered "after graceful stop"

echo "==> second docker kill -s KILL + docker start"
docker kill -s KILL "$FOX" >/dev/null
docker start "$FOX" >/dev/null
check_recovered "after second SIGKILL"

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
