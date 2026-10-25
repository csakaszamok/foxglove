#!/bin/bash
# Integration test: only ports published on all interfaces get an frp proxy;
# ports published on loopback (127.0.0.1, 127.x, ::1) stay private. The
# readiness marker (<instance>.ready, stcp) is registered even when no port
# is exposed.
#
# Runs against the host Docker daemon. Usage:
#   IMAGE=ghcr.io/csakaszamok/foxglove:0.9.0-dind bash tests/test-private-ports.sh
#   IMAGE=ghcr.io/csakaszamok/foxglove:0.9.0-sysbox RUN_OPTS="--runtime=sysbox-runc" bash tests/test-private-ports.sh
set -u
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: don't rewrite /etc/... args

IMAGE=${IMAGE:?set IMAGE to the foxglove image under test}
RUN_OPTS=${RUN_OPTS:---privileged}
ECHO_IMAGE=${ECHO_IMAGE:-hashicorp/http-echo}
FRPS_IMAGE=${FRPS_IMAGE:-fatedier/frps:v0.62.1}
TIMEOUT=${TIMEOUT:-60}

P=fgpp-$$
NET=$P-net
FRPS=$P-frps
FOX=$P-fox
INSTANCE=fgpp
DOMAIN=test.local
TOKEN=test-token

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

cleanup() {
    docker rm -f "$FOX" "$FRPS" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT

wait_for() {
    local timeout=$1; shift
    local t=0
    while [ "$t" -lt "$timeout" ]; do
        if "$@"; then return 0; fi
        sleep 1
        t=$((t + 1))
    done
    return 1
}

# fetch <url> [Host header]: GET from a throwaway container on $NET
fetch() {
    docker run --rm --network "$NET" --entrypoint wget "$IMAGE" -q -T 3 -O - \
        ${2:+--header "Host: $2"} "$1" 2>/dev/null
}
api() { fetch "http://$FRPS:7500/api/proxy/$1"; }
# proxy_names <type>: names of the online proxies of that type, one per line
# a Python that runs (on Windows `python3` may be the Microsoft Store stub)
PY=
for c in python3 python; do "$c" -c pass 2>/dev/null && { PY=$c; break; }; done
[ -n "$PY" ] || { echo "python is required" >&2; exit 1; }
proxy_names() {
    api "$1" | "$PY" -c 'import json,sys
for p in json.load(sys.stdin).get("proxies") or []:
    if p.get("status") == "online": print(p["name"])' 2>/dev/null | tr -d '\r'
}
online() { proxy_names "$1" | grep -qx "$2"; }
via_frps() { fetch "http://$FRPS:8080/" "$1.$DOMAIN"; }

echo "==> Image under test: $IMAGE ($RUN_OPTS)"
docker network create "$NET" >/dev/null
docker create --name "$FRPS" --network "$NET" "$FRPS_IMAGE" -c /etc/frp/frps.toml >/dev/null
d=$(mktemp -d); mkdir -p "$d/frp" "$d/instance"
printf 'bindPort = 7000\nvhostHTTPPort = 8080\n[auth]\ntoken = "%s"\n[webServer]\naddr = "0.0.0.0"\nport = 7500\n' "$TOKEN" > "$d/frp/frps.toml"
src=$d; command -v cygpath >/dev/null && src=$(cygpath -w "$d")
docker cp "$src/frp/." "$FRPS:/etc/frp" >/dev/null
docker start "$FRPS" >/dev/null

# shellcheck disable=SC2086
docker create --name "$FOX" --network "$NET" $RUN_OPTS \
    -e FRP_SERVER_ADDR="$FRPS" -e FRP_SERVER_PORT=7000 \
    -e FRP_TOKEN="$TOKEN" -e BASE_DOMAIN="$DOMAIN" \
    "$IMAGE" >/dev/null
echo "$INSTANCE" > "$d/instance/name"
docker cp "$src/instance/." "$FOX:/etc/instance" >/dev/null
rm -rf "$d"
docker start "$FOX" >/dev/null

# --- readiness marker with no inner containers at all
if wait_for "$TIMEOUT" online stcp "$INSTANCE.ready"; then
    pass "readiness marker $INSTANCE.ready online with no exposed ports"
else
    fail "readiness marker not online (stcp: $(api stcp))"
    docker logs "$FOX" 2>&1 | grep -v "level=" | tail -40
    docker exec "$FOX" grep -A1 "^name" /etc/frpc/frpc.toml
fi
if [ -z "$(proxy_names http)" ]; then
    pass "marker is not listed among HTTP proxies"
else
    fail "unexpected HTTP proxies: $(proxy_names http)"
fi

wait_for "$TIMEOUT" docker exec "$FOX" docker info >/dev/null 2>&1 || { fail "inner dockerd did not come up"; exit 1; }
inner() { docker exec "$FOX" docker run -d "$@" >/dev/null || fail "inner docker run $*"; }
inner --name echo-a -p 127.0.0.1:5678:5678 "$ECHO_IMAGE" -text=a
inner --name echo-b -p 5679:5678 "$ECHO_IMAGE" -text=b
inner --name echo-c -p 0.0.0.0:5680:5678 "$ECHO_IMAGE" -text=c
inner --name echo-v6 -p '[::1]:5681:5678' -p 127.0.0.2:5682:5679 "$ECHO_IMAGE" -text=v6
inner --name sub-priv -l p9m.subdomain=priv -p 127.0.0.1:5683:5678 "$ECHO_IMAGE" -text=priv
inner --name sub-pub -l p9m.subdomain=pub -p 5684:5678 "$ECHO_IMAGE" -text=pub
inner --name sub-old -l p7y.subdomain=old -l frpc.subdomain=old -p 5686:5678 "$ECHO_IMAGE" -text=old

if wait_for "$TIMEOUT" online http "$INSTANCE-echo-b-port5679" && wait_for 10 online http "$INSTANCE-pub"; then
    pass "all-interface ports registered"
else
    fail "all-interface ports not registered (http: $(proxy_names http | tr '\n' ' '))"
fi
sleep 3 # let any further (wrong) reload land before checking for absence
names=$(proxy_names http | sort | tr '\n' ' ')
expected="$INSTANCE-echo-b-port5679 $INSTANCE-echo-c-port5680 $INSTANCE-pub $INSTANCE-sub-old-port5686 "
if [ "$names" = "$expected" ]; then
    pass "HTTP proxies are exactly the all-interface ones: $names"
else
    fail "HTTP proxies: got '$names', want '$expected'"
fi
online stcp "$INSTANCE.ready" && pass "readiness marker still online" || fail "readiness marker gone"

[ "$(via_frps "$INSTANCE-echo-b-port5679")" = b ] && pass "echo-b answers through frps" \
    || fail "echo-b through frps (got: $(via_frps "$INSTANCE-echo-b-port5679"))"
[ "$(via_frps "$INSTANCE-pub")" = pub ] && pass "p9m.subdomain container answers as $INSTANCE-pub" \
    || fail "$INSTANCE-pub through frps"
[ "$(via_frps "$INSTANCE-sub-old-port5686")" = old ] && pass "old labels are ignored (generated name $INSTANCE-sub-old-port5686)" \
    || fail "$INSTANCE-sub-old-port5686 through frps"
for name in "$INSTANCE-echo-a-port5678" "$INSTANCE-priv" "$INSTANCE-echo-v6-port5681"; do
    out=$(via_frps "$name")
    case "$out" in
        a|priv|v6) fail "$name reaches the loopback-published app ($out)" ;;
        *) pass "$name does not reach its app" ;;
    esac
done

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
