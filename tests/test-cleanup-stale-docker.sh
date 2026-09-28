#!/bin/sh
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

ORIG_PATH=$PATH
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; export PATH=$ORIG_PATH; }
trap cleanup EXIT

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$ORIG_PATH"
RUN="$TMP/run"

# mock_pgrep <running process names...>: pgrep -x NAME succeeds only for these
mock_pgrep() {
    printf '#!/bin/sh\nfor p in %s; do [ "$2" = "$p" ] && exit 0; done\nexit 1\n' "$*" > "$TMP/bin/pgrep"
    chmod +x "$TMP/bin/pgrep"
}

seed() {
    rm -rf "$RUN"
    mkdir -p "$RUN/docker/containerd"
    touch "$RUN/docker.sock" "$RUN/docker.pid" "$RUN/docker/containerd/containerd.pid"
}

# Test: removes stale files when neither dockerd nor containerd runs
seed; mock_pgrep none
DOCKER_RUN_DIR="$RUN" sh cleanup-stale-docker.sh >/dev/null
if [ ! -e "$RUN/docker.sock" ] && [ ! -e "$RUN/docker.pid" ] && [ ! -e "$RUN/docker/containerd/containerd.pid" ]; then
    pass "removes stale socket and pid files"
else
    fail "removes stale socket and pid files ($(find "$RUN" -type f))"
fi

# Test: keeps everything while dockerd and containerd are running
seed; mock_pgrep dockerd containerd
DOCKER_RUN_DIR="$RUN" sh cleanup-stale-docker.sh >/dev/null
if [ -e "$RUN/docker.sock" ] && [ -e "$RUN/docker.pid" ] && [ -e "$RUN/docker/containerd/containerd.pid" ]; then
    pass "keeps files while dockerd is running"
else
    fail "keeps files while dockerd is running"
fi

# Test: dockerd gone but containerd alive -> only docker files removed
seed; mock_pgrep containerd
DOCKER_RUN_DIR="$RUN" sh cleanup-stale-docker.sh >/dev/null
if [ ! -e "$RUN/docker.sock" ] && [ -e "$RUN/docker/containerd/containerd.pid" ]; then
    pass "keeps containerd.pid while containerd is running"
else
    fail "keeps containerd.pid while containerd is running"
fi

# Test: succeeds when there is nothing to clean
rm -rf "$RUN"; mock_pgrep none
if DOCKER_RUN_DIR="$RUN" sh cleanup-stale-docker.sh >/dev/null; then
    pass "exits 0 when nothing to clean"
else
    fail "exits 0 when nothing to clean"
fi

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
