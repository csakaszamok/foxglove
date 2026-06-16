#!/bin/sh
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

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

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
