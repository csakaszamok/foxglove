#!/bin/sh
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

ORIG_PATH=$PATH
MOCK_DIR=$(mktemp -d)
cleanup() { rm -rf "$MOCK_DIR"; export PATH=$ORIG_PATH; }
trap cleanup EXIT

# Test: exits 1 when socket never appears (short timeout)
if DOCKER_SOCK=/tmp/nonexistent-docker-sock-xyz TIMEOUT=3 INTERVAL=1 sh wait-for-docker.sh 2>/dev/null; then
    fail "exits 1 when socket missing after timeout"
else
    pass "exits 1 when socket missing after timeout"
fi

# Test: error message mentions the socket path
output=$(DOCKER_SOCK=/tmp/no-sock-abc TIMEOUT=2 INTERVAL=1 sh wait-for-docker.sh 2>&1 || true)
if echo "$output" | grep -q "no-sock-abc"; then
    pass "error message includes socket path"
else
    fail "error message includes socket path (got: $output)"
fi

# Test: stale socket (daemon not answering) is not treated as ready
cat > "$MOCK_DIR/docker" <<'EOF'
#!/bin/sh
echo "Cannot connect to the Docker daemon" >&2
exit 1
EOF
chmod +x "$MOCK_DIR/docker"
export PATH="$MOCK_DIR:$ORIG_PATH"

if TIMEOUT=2 INTERVAL=1 sh wait-for-docker.sh >/dev/null 2>&1; then
    fail "keeps waiting while daemon does not answer"
else
    pass "keeps waiting while daemon does not answer"
fi

# Test: returns once the daemon answers (3rd poll), queries the given socket
COUNTER_FILE="$MOCK_DIR/count"
ARGS_FILE="$MOCK_DIR/args"
echo 0 > "$COUNTER_FILE"
cat > "$MOCK_DIR/docker" <<EOF
#!/bin/sh
echo "\$@" > $ARGS_FILE
n=\$(cat $COUNTER_FILE)
n=\$((n + 1))
echo \$n > $COUNTER_FILE
[ \$n -ge 3 ]
EOF
chmod +x "$MOCK_DIR/docker"

if DOCKER_SOCK=/tmp/test-docker.sock TIMEOUT=10 INTERVAL=0 sh wait-for-docker.sh >/dev/null 2>&1 \
    && [ "$(cat "$COUNTER_FILE")" -eq 3 ]; then
    pass "returns 0 once daemon answers"
else
    fail "returns 0 once daemon answers (polls: $(cat "$COUNTER_FILE"))"
fi

if grep -q "unix:///tmp/test-docker.sock" "$ARGS_FILE"; then
    pass "queries daemon on DOCKER_SOCK"
else
    fail "queries daemon on DOCKER_SOCK (args: $(cat "$ARGS_FILE"))"
fi

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
