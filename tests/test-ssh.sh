#!/bin/bash
# Integration test: key-only root SSH into a foxglove sandbox, as the p7y
# gateway reaches it (port 22 on a shared docker network).
#   - login with the authorized key works and `docker ps` uses the inner dockerd
#   - password / keyboard-interactive and a wrong key are refused
#   - without /etc/instance/authorized_keys sshd runs but nobody gets in
#   - host keys in a mounted /etc/ssh/host-keys survive container re-creation
#   - replacing authorized_keys at runtime takes effect without a restart
#
# Runs against the host Docker daemon. Usage:
#   IMAGE=ghcr.io/p7y-dev/foxglove:0.7.0-dind bash tests/test-ssh.sh
set -u
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: don't rewrite /etc/... args

IMAGE=${IMAGE:?set IMAGE to the foxglove image under test}
RUN_OPTS=${RUN_OPTS:---privileged}
# The client needs an ssh binary; the dind image has openssh-client.
CLIENT_IMAGE=${CLIENT_IMAGE:-$IMAGE}

P=fgssh-$$
NET=$P-net
FOX=$P-fox
FOX_NOKEYS=$P-nokeys

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
mkdir -p "$WORK/instance" "$WORK/host-keys" "$WORK/keys"
winpath() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }

cleanup() {
    docker rm -f "$FOX" "$FOX_NOKEYS" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$WORK"
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

# client <cmd>: run a shell command in a throwaway container on $NET with the
# test keys at /keys (copied to /tmp so ssh accepts their permissions).
client() {
    docker run --rm --network "$NET" -v "$(winpath "$WORK/keys"):/keys:ro" \
        --entrypoint sh "$CLIENT_IMAGE" -c \
        'mkdir -p /tmp/k && cp /keys/* /tmp/k/ && chmod 600 /tmp/k/* && '"$1"
}

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR"

# ssh_as <key> <host> <cmd...>
ssh_as() {
    local key=$1 host=$2; shift 2
    client "ssh $SSH_OPTS -o IdentitiesOnly=yes -i /tmp/k/$key root@$host '$*'" 2>&1
}

host_fp() {
    client "ssh-keyscan -t ed25519 $1 2>/dev/null > /tmp/kh && ssh-keygen -lf /tmp/kh" 2>/dev/null | awk '{print $2}'
}

sshd_up() { [ -n "$(host_fp "$1")" ]; }

# start_fox <name> [extra docker run args...]
start_fox() {
    local name=$1; shift
    # shellcheck disable=SC2086
    docker run -d --name "$name" --network "$NET" $RUN_OPTS \
        -e FRP_TOKEN=test-token -e BASE_DOMAIN=test.local \
        -v "$(winpath "$WORK/instance/name"):/etc/instance/name:ro" \
        "$@" "$IMAGE" >/dev/null
}

echo "==> Image under test: $IMAGE ($RUN_OPTS)"
echo fgssh > "$WORK/instance/name"
ssh-keygen -q -t ed25519 -N '' -C good -f "$WORK/keys/good"
ssh-keygen -q -t ed25519 -N '' -C wrong -f "$WORK/keys/wrong"
ssh-keygen -q -t ed25519 -N '' -C rotated -f "$WORK/keys/rotated"
cp "$WORK/keys/good.pub" "$WORK/instance/authorized_keys"

docker network create "$NET" >/dev/null
start_fox "$FOX" \
    -v "$(winpath "$WORK/instance/authorized_keys"):/etc/instance/authorized_keys:ro" \
    -v "$(winpath "$WORK/host-keys"):/etc/ssh/host-keys"

if ! wait_for 60 sshd_up "$FOX"; then
    fail "sshd did not come up"; docker logs "$FOX" 2>&1 | tail -30; exit 1
fi
wait_for 60 docker exec "$FOX" docker info >/dev/null 2>&1 || fail "inner dockerd did not come up"
# the inner dockerd names itself after the sandbox container's hostname
inner_name=$(docker exec "$FOX" hostname)

# --- login with the authorized key, docker ps against the inner dockerd
out=$(ssh_as good "$FOX" 'echo user=$(id -un) shell=$0 host=${DOCKER_HOST:-unset}; docker ps && echo daemon=$(docker info --format "{{.Name}}")')
if echo "$out" | grep -q 'user=root shell=bash host=unset' && echo "$out" | grep -q '^CONTAINER ID' \
    && echo "$out" | grep -qx "daemon=$inner_name"; then
    pass "login as root with key, bash shell, docker ps hits the inner dockerd"
else
    fail "login with key / docker ps (got: $out)"
fi

# --- password / keyboard-interactive refused (server offers only publickey)
out=$(client "ssh $SSH_OPTS -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive root@$FOX true" 2>&1)
if echo "$out" | grep -q 'Permission denied (publickey)'; then
    pass "password and keyboard-interactive auth not offered"
else
    fail "password auth refused (got: $out)"
fi

# --- wrong key refused
out=$(ssh_as wrong "$FOX" true)
if echo "$out" | grep -q 'Permission denied'; then
    pass "wrong key refused"
else
    fail "wrong key refused (got: $out)"
fi

# --- ~/.ssh/authorized_keys is not a back door (only the p7y file counts)
docker exec "$FOX" sh -c "mkdir -p /root/.ssh && echo '$(cat "$WORK/keys/wrong.pub")' > /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys"
out=$(ssh_as wrong "$FOX" true)
if echo "$out" | grep -q 'Permission denied'; then
    pass "~/.ssh/authorized_keys ignored"
else
    fail "~/.ssh/authorized_keys ignored (got: $out)"
fi
docker exec "$FOX" rm -rf /root/.ssh

# --- authorized_keys replaced at runtime (in place, as a bind mount sees it)
cat "$WORK/keys/rotated.pub" > "$WORK/instance/authorized_keys"
out_new=$(ssh_as rotated "$FOX" echo ok)
out_old=$(ssh_as good "$FOX" echo ok)
if [ "$out_new" = ok ] && echo "$out_old" | grep -q 'Permission denied'; then
    pass "key rotation takes effect without restart"
else
    fail "key rotation (new: $out_new / old: $out_old)"
fi

# --- host key persists across container re-creation with the same mount
fp1=$(host_fp "$FOX")
docker rm -f "$FOX" >/dev/null
start_fox "$FOX" \
    -v "$(winpath "$WORK/instance/authorized_keys"):/etc/instance/authorized_keys:ro" \
    -v "$(winpath "$WORK/host-keys"):/etc/ssh/host-keys"
wait_for 60 sshd_up "$FOX"
fp2=$(host_fp "$FOX")
docker logs "$FOX" 2>&1 | grep "SSH host key" | sed "s/^/    log: /"
if [ -n "$fp1" ] && [ "$fp1" = "$fp2" ]; then
    pass "host key fingerprint stable across re-creation ($fp1)"
else
    fail "host key fingerprint changed ($fp1 -> $fp2)"
fi
ls "$WORK/host-keys" | grep -q '^ssh_host_rsa_key$' && ls "$WORK/host-keys" | grep -q '^ssh_host_ecdsa_key$' \
    && pass "ed25519/rsa/ecdsa host keys written to the mounted dir" \
    || fail "host keys in mounted dir (got: $(ls "$WORK/host-keys"))"

# --- no authorized_keys and no host-keys mount: sandbox starts, sshd runs, nobody in
start_fox "$FOX_NOKEYS"
if wait_for 60 sshd_up "$FOX_NOKEYS"; then
    pass "without authorized_keys/host-keys mounts sshd is up"
else
    fail "sshd up without mounts"; docker logs "$FOX_NOKEYS" 2>&1 | tail -30
fi
wait_for 60 docker exec "$FOX_NOKEYS" docker info >/dev/null 2>&1
status=$(docker exec "$FOX_NOKEYS" ps -o args)
if echo "$status" | grep -q "^sshd: /usr/sbin/sshd -D -e" && echo "$status" | grep -qE "^dockerd( |$)"; then
    pass "dockerd and sshd (sshd -D -e) running"
else
    fail "sshd/dockerd processes (got: $status)"
fi
out=$(ssh_as good "$FOX_NOKEYS" true)
if echo "$out" | grep -q 'Permission denied'; then
    pass "without authorized_keys nobody can log in"
else
    fail "login refused without authorized_keys (got: $out)"
fi

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
