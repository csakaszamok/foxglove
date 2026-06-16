#!/bin/sh
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

ORIG_PATH=$PATH
MOCK_DIR=$(mktemp -d)
cleanup() { rm -rf "$MOCK_DIR"; export PATH=$ORIG_PATH; }
trap cleanup EXIT

# Test: exits 0 when frpc succeeds on first attempt
cat > "$MOCK_DIR/frpc" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_DIR/frpc"
export PATH="$MOCK_DIR:$PATH"

if RETRY_DELAY=0 sh frpc-reload.sh 2>/dev/null; then
    pass "exits 0 when frpc succeeds immediately"
else
    fail "exits 0 when frpc succeeds immediately"
fi

# Test: retries and exits 0 when frpc succeeds on 2nd attempt
COUNTER_FILE=$(mktemp)
echo 0 > "$COUNTER_FILE"
cat > "$MOCK_DIR/frpc" <<EOF
#!/bin/sh
n=\$(cat $COUNTER_FILE)
n=\$((n + 1))
echo \$n > $COUNTER_FILE
[ \$n -ge 2 ]
EOF
chmod +x "$MOCK_DIR/frpc"

if RETRY_DELAY=0 sh frpc-reload.sh 2>/dev/null; then
    pass "retries and exits 0 on 2nd attempt"
else
    fail "retries and exits 0 on 2nd attempt"
fi

# Test: exits 1 after max retries exhausted
cat > "$MOCK_DIR/frpc" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$MOCK_DIR/frpc"

if RETRY_DELAY=0 sh frpc-reload.sh 2>/dev/null; then
    fail "exits 1 after max retries exhausted"
else
    pass "exits 1 after max retries exhausted"
fi

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
