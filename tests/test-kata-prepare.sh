#!/bin/sh
# Unit tests for kata-prepare.sh. Run from the repo root. mount/umount are mocked on PATH.
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMPDIR=$(mktemp -d)
cleanup() { chmod -R u+rwx "$TMPDIR" 2>/dev/null; rm -rf "$TMPDIR"; }
trap cleanup EXIT

mkdir -p "$TMPDIR/bin"
# mount: log; MOUNT_FIX=1 makes "remount,rw $CGROUP_DIR" succeed by making the dir writable
cat > "$TMPDIR/bin/mount" <<'M'
#!/bin/sh
echo "mount $*" >> "$TMPDIR/calls"
if [ "${MOUNT_FIX:-}" = 1 ] && [ "$*" = "-o remount,rw $CGROUP_DIR" ]; then chmod 755 "$CGROUP_DIR"; fi
exit 0
M
cat > "$TMPDIR/bin/umount" <<'M'
#!/bin/sh
echo "umount $*" >> "$TMPDIR/calls"
exit "${UMOUNT_RC:-0}"
M
chmod +x "$TMPDIR/bin/mount" "$TMPDIR/bin/umount"
export TMPDIR

IS_ROOT=0
[ "$(id -u)" = 0 ] && IS_ROOT=1

# run_kp: fresh calls log, fresh writable cgroup dir; extra env passed by the caller via the environment
run_kp() {
    : > "$TMPDIR/calls"
    PATH="$TMPDIR/bin:$PATH" RESOLV_CONF="$TMPDIR/resolv.conf" SYS_DIR="$TMPDIR/sys" \
        CGROUP_DIR="$TMPDIR/cgroup" sh kata-prepare.sh 2>"$TMPDIR/stderr" >"$TMPDIR/stdout"
}
reset_cgroup() { chmod 755 "$TMPDIR/cgroup" 2>/dev/null; rm -rf "$TMPDIR/cgroup"; mkdir -p "$TMPDIR/cgroup"; }

# Test: dns written
reset_cgroup
rc=0; DNS_SERVER=10.213.0.2 run_kp || rc=$?
if [ "$(cat "$TMPDIR/resolv.conf" 2>/dev/null)" = "nameserver 10.213.0.2
options ndots:0" ] && grep -qxF "umount $TMPDIR/resolv.conf" "$TMPDIR/calls"; then
    pass "dns written"
else
    fail "dns written (rc=$rc, resolv: $(cat "$TMPDIR/resolv.conf" 2>&1), calls: $(cat "$TMPDIR/calls"))"
fi

# Test: dns unset leaves resolv.conf
reset_cgroup
printf 'nameserver 1.2.3.4\n' > "$TMPDIR/resolv.conf"
rc=0; (unset DNS_SERVER; run_kp) || rc=$?
if [ "$(cat "$TMPDIR/resolv.conf")" = "nameserver 1.2.3.4" ] && ! grep -q '^umount' "$TMPDIR/calls"; then
    pass "dns unset leaves resolv.conf"
else
    fail "dns unset leaves resolv.conf (rc=$rc, calls: $(cat "$TMPDIR/calls"))"
fi

# Test: umount failure tolerated
reset_cgroup
rm -f "$TMPDIR/resolv.conf"
rc=0; UMOUNT_RC=1 DNS_SERVER=10.213.0.2 run_kp || rc=$?
if [ "$rc" = 0 ] && [ "$(sed -n 1p "$TMPDIR/resolv.conf")" = "nameserver 10.213.0.2" ]; then
    pass "umount failure tolerated"
else
    fail "umount failure tolerated (rc=$rc)"
fi

# Test: sys remounted
reset_cgroup
rc=0; run_kp || rc=$?
if grep -qF -- "-o remount,rw $TMPDIR/sys" "$TMPDIR/calls"; then
    pass "sys remounted"
else
    fail "sys remounted (calls: $(cat "$TMPDIR/calls"))"
fi

# Test: cgroup writable: no cgroup remount
reset_cgroup
rc=0; run_kp || rc=$?
if [ "$rc" = 0 ] && ! grep -qF "$TMPDIR/cgroup" "$TMPDIR/calls"; then
    pass "cgroup writable: no cgroup remount"
else
    fail "cgroup writable: no cgroup remount (rc=$rc, calls: $(cat "$TMPDIR/calls"))"
fi

if [ "$IS_ROOT" = 1 ]; then
    echo "SKIP: cgroup read-only then fixed (root ignores chmod 555)"
    echo "SKIP: cgroup stays read-only: exit 1 (root ignores chmod 555)"
else
    # Test: cgroup read-only then fixed
    reset_cgroup; chmod 555 "$TMPDIR/cgroup"
    rc=0; MOUNT_FIX=1 run_kp || rc=$?
    if [ "$rc" = 0 ] && grep -qF -- "-o remount,rw $TMPDIR/cgroup" "$TMPDIR/calls"; then
        pass "cgroup read-only then fixed"
    else
        fail "cgroup read-only then fixed (rc=$rc, calls: $(cat "$TMPDIR/calls"))"
    fi

    # Test: cgroup stays read-only: exit 1
    reset_cgroup; chmod 555 "$TMPDIR/cgroup"
    rc=0; run_kp || rc=$?
    if [ "$rc" = 1 ] && grep -qF "/sys/fs/cgroup is not writable ($TMPDIR/cgroup)" "$TMPDIR/stderr"; then
        pass "cgroup stays read-only: exit 1"
    else
        fail "cgroup stays read-only: exit 1 (rc=$rc, stderr: $(cat "$TMPDIR/stderr"))"
    fi
fi

echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
