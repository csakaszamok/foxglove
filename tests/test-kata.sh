#!/bin/bash
# Integration test: the -kata image under Kata Containers (needs a host with KVM and a "kata" Docker runtime).
# A compose project with a CoreDNS sidecar at a fixed address (Docker's embedded DNS is unreachable from the Kata
# guest), frps, and the sandbox. Checks that the inner dockerd comes up, resolv.conf and frpc use the sidecar,
# sshd runs, inner containers resolve outer names, and all of it survives docker stop/start.
#
# Usage:
#   IMAGE=foxglove:kata-ci bash tests/test-kata.sh
set -u
export MSYS_NO_PATHCONV=1

IMAGE=${IMAGE:?set IMAGE to the foxglove -kata image under test}
RUN_OPTS=${RUN_OPTS:---runtime kata --cap-add ALL --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt systempaths=unconfined --device-cgroup-rule 'a *:* rwm'}

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# RUN_OPTS is the docker-run flag set; translate it to the compose service keys
RUNTIME=kata
CAP_ADD=
SEC_OPT=
DEV_RULE=
set -- $RUN_OPTS
while [ $# -gt 0 ]; do
    case "$1" in
        --runtime) RUNTIME=$2; shift 2 ;;
        --runtime=*) RUNTIME=${1#*=}; shift ;;
        --cap-add) CAP_ADD="$CAP_ADD, $2"; shift 2 ;;
        --security-opt) SEC_OPT="$SEC_OPT, $2"; shift 2 ;;
        --device-cgroup-rule) DEV_RULE="$DEV_RULE, $2"; shift 2 ;;
        *) echo "unsupported RUN_OPTS word: $1" >&2; exit 1 ;;
    esac
done
# a rule such as 'a *:* rwm' keeps its quotes from the shell split; strip them
DEV_RULE=$(printf '%s' "$DEV_RULE" | tr -d "'")

W=$(mktemp -d)
PROJECT=fgkata$$
SB=$PROJECT-sandbox-1
export COMPOSE_PROJECT_NAME=$PROJECT

cleanup() {
    ( cd "$W" && docker compose down -v >/dev/null 2>&1 )
    rm -rf "$W"
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

inner_up() { docker exec "$SB" docker info >/dev/null 2>&1; }
logins() { docker logs "$SB" 2>&1 | grep -c 'login to server success'; }

printf '.:53 {\n  forward . 127.0.0.11\n  cache 5\n  errors\n}\n' > "$W/Corefile"
printf 'bindPort = 7000
auth.method = "token"
auth.token = "t"
' > "$W/frps.toml"
echo kata > "$W/name"
cat > "$W/compose.yaml" <<YAML
services:
  dns:
    image: coredns/coredns:1.11.3
    command: ["-conf", "/etc/coredns/Corefile"]
    volumes: ["./Corefile:/etc/coredns/Corefile:ro"]
    networks: {default: {ipv4_address: 172.31.0.2}}
  frps:
    image: fatedier/frps:v0.62.1
    command: ["-c", "/etc/frp/frps.toml"]
    volumes: ["./frps.toml:/etc/frp/frps.toml:ro"]
  sandbox:
    image: $IMAGE
    runtime: $RUNTIME
    cap_add: [${CAP_ADD#, }]
    security_opt: [${SEC_OPT#, }]
    device_cgroup_rules: ['${DEV_RULE#, }']
    depends_on: [dns, frps]
    environment:
      DNS_SERVER: 172.31.0.2
      FRP_SERVER_ADDR: frps
      FRP_SERVER_PORT: "7000"
      FRP_TOKEN: t
      BASE_DOMAIN: test.local
    volumes: ["./name:/etc/instance/name:ro", "docker_data:/var/lib/docker"]
networks:
  default:
    # dynamic addresses only in the upper half, so the sidecar's fixed address is never handed out first
    ipam: {config: [{subnet: 172.31.0.0/24, ip_range: 172.31.0.128/25}]}
volumes: {docker_data: {}}
YAML

( cd "$W" && docker compose up -d ) || { fail "compose up"; exit 1; }

# 1. inner dockerd
if wait_for 120 inner_up; then pass "inner dockerd answers docker info"; else
    fail "inner dockerd did not come up within 120s"
    docker logs --tail 40 "$SB" 2>&1 | sed 's/^/    /'
fi

# 2. resolv.conf
ns=$(docker exec "$SB" grep nameserver /etc/resolv.conf 2>&1)
if [ "$ns" = "nameserver 172.31.0.2" ]; then pass "resolv.conf uses the DNS sidecar"; else fail "resolv.conf: '$ns'"; fi

# 3. frpc reached frps by name
if wait_for 60 sh -c "[ \$(docker logs $SB 2>&1 | grep -c 'login to server success') -gt 0 ]"; then
    pass "frpc logged in to frps by name"
else
    fail "no 'login to server success' within 60s"
    docker logs --tail 40 "$SB" 2>&1 | sed 's/^/    /'
fi

# 4. sshd
if docker exec "$SB" pgrep -f sshd >/dev/null 2>&1; then pass "sshd is running"; else fail "sshd is not running"; fi

# 5. inner containers resolve outer names
out=$(docker exec "$SB" docker run --rm alpine nslookup frps 2>&1)
if echo "$out" | awk '/^Name:/ {f=1} f && /^Address/ {print $NF; exit}' | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    pass "inner container resolves the outer name frps"
else
    fail "inner nslookup frps: $out"
fi

# 6. stop/start
before=$(logins)
docker stop -t 20 "$SB" >/dev/null && docker start "$SB" >/dev/null
if wait_for 120 inner_up; then pass "after restart: inner dockerd answers docker info"; else
    fail "after restart: inner dockerd did not come up within 120s"
    docker logs --tail 40 "$SB" 2>&1 | sed 's/^/    /'
fi
if wait_for 60 sh -c "[ \$(docker logs $SB 2>&1 | grep -c 'login to server success') -gt $before ]"; then
    pass "after restart: frpc logged in to frps again"
else
    fail "after restart: no new 'login to server success' within 60s"
    docker logs --tail 40 "$SB" 2>&1 | sed 's/^/    /'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
