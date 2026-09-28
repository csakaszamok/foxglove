#!/bin/sh
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Mock supervisord so entrypoint can complete without it
mkdir -p "$TMPDIR/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMPDIR/bin/supervisord"
chmod +x "$TMPDIR/bin/supervisord"

run_ep() {
    # FRPC_CONFIG_DIR overrides where entrypoint writes frpc.toml
    PATH="$TMPDIR/bin:$PATH" FRPC_CONFIG_DIR="$TMPDIR/frpc" sh entrypoint.sh 2>&1
}

# Test: fails when instance name file missing
result=$(INSTANCE_NAME_FILE=/tmp/no-such-file-xyz \
    FRP_SERVER_ADDR=a FRP_SERVER_PORT=7000 FRP_TOKEN=t BASE_DOMAIN=x.local \
    run_ep || true)
if echo "$result" | grep -qi "instance"; then
    pass "detects missing instance name file"
else
    fail "detects missing instance name file (got: $result)"
fi

# Test: fails when instance name file is empty
printf '' > "$TMPDIR/name-empty"
result=$(INSTANCE_NAME_FILE="$TMPDIR/name-empty" \
    FRP_SERVER_ADDR=a FRP_SERVER_PORT=7000 FRP_TOKEN=t BASE_DOMAIN=x.local \
    run_ep || true)
if echo "$result" | grep -qi "empty\|instance"; then
    pass "detects empty instance name file"
else
    fail "detects empty instance name file (got: $result)"
fi

printf 'worker01' > "$TMPDIR/name"

# Test: fails when BASE_DOMAIN is missing
result=$(INSTANCE_NAME_FILE="$TMPDIR/name" \
    FRP_SERVER_ADDR=a FRP_SERVER_PORT=7000 FRP_TOKEN=t \
    run_ep || true)
if echo "$result" | grep -q "BASE_DOMAIN"; then
    pass "detects missing BASE_DOMAIN"
else
    fail "detects missing BASE_DOMAIN (got: $result)"
fi

# Test: succeeds with all required config present and writes frpc.toml
mkdir -p "$TMPDIR/frpc"
result=$(INSTANCE_NAME_FILE="$TMPDIR/name" \
    FRP_SERVER_ADDR=frp.example.com FRP_SERVER_PORT=7000 FRP_TOKEN=secret BASE_DOMAIN=my.local \
    run_ep)
if [ -f "$TMPDIR/frpc/frpc.toml" ] && grep -q "frp.example.com" "$TMPDIR/frpc/frpc.toml"; then
    pass "writes frpc.toml with server address when all config present"
else
    fail "writes frpc.toml when all config present (got: $result)"
fi

# Test: FRP_SERVER_ADDR/PORT defaults are exported (docker-gen renders frpc.tmpl from env)
printf '#!/bin/sh\nenv > "%s"\n' "$TMPDIR/env" > "$TMPDIR/bin/supervisord"
result=$(unset FRP_SERVER_ADDR FRP_SERVER_PORT; INSTANCE_NAME_FILE="$TMPDIR/name" \
    FRP_TOKEN=secret BASE_DOMAIN=my.local \
    run_ep)
if grep -q '^FRP_SERVER_ADDR=frps$' "$TMPDIR/env" && grep -q '^FRP_SERVER_PORT=7000$' "$TMPDIR/env"; then
    pass "exports FRP_SERVER_ADDR/FRP_SERVER_PORT defaults to supervisord"
else
    fail "exports FRP_SERVER_ADDR/FRP_SERVER_PORT defaults (env: $(grep FRP_ "$TMPDIR/env"))"
fi

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
