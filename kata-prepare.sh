#!/bin/sh
# Prepare a Kata Containers guest for the sandbox: run before entrypoint.sh.
#
# - Docker mounts /sys and the cgroup tree read-only for a non-privileged container, but the inner dockerd needs
#   them writable. A Kata guest is a VM, so remounting only touches the guest's own kernel, not the host.
# - Docker's embedded DNS (127.0.0.11) is unreachable from the guest, so when DNS_SERVER is set (a DNS sidecar at a
#   fixed address) resolv.conf is rewritten to use it.
#
# Environment: DNS_SERVER (optional), RESOLV_CONF, SYS_DIR, CGROUP_DIR (the last three default to the real paths,
# tests override them). Exits 1 when the cgroup dir stays read-only. Stdout: one "kata-prepare:" line per action.
set -e

RESOLV_CONF=${RESOLV_CONF:-/etc/resolv.conf}
SYS_DIR=${SYS_DIR:-/sys}
CGROUP_DIR=${CGROUP_DIR:-/sys/fs/cgroup}

if [ -n "${DNS_SERVER:-}" ]; then
    umount "$RESOLV_CONF" 2>/dev/null || true
    printf 'nameserver %s\noptions ndots:0\n' "$DNS_SERVER" > "$RESOLV_CONF"
    echo "kata-prepare: resolv.conf uses $DNS_SERVER"
elif grep -q '127\.0\.0\.11' "$RESOLV_CONF" 2>/dev/null; then
    echo "kata-prepare: warning: $RESOLV_CONF uses Docker's embedded DNS (127.0.0.11), unreachable from a Kata guest; set DNS_SERVER to a DNS sidecar" >&2
fi

if mount -o remount,rw "$SYS_DIR"; then
    echo "kata-prepare: remounted $SYS_DIR read-write"
else
    echo "kata-prepare: warning: could not remount $SYS_DIR read-write" >&2
fi

cgroup_writable() {
    if mkdir "$CGROUP_DIR/.kata-w" 2>/dev/null; then
        rmdir "$CGROUP_DIR/.kata-w"
        return 0
    fi
    return 1
}

if ! cgroup_writable; then
    fixed=0
    if mount -o remount,rw "$CGROUP_DIR" 2>/dev/null; then
        echo "kata-prepare: remounted $CGROUP_DIR read-write"
        fixed=1
    else
        # A failed fallback must be fatal: after umount alone, the probe would succeed on the plain directory
        umount "$CGROUP_DIR" 2>/dev/null || true
        if mount -t cgroup2 cgroup2 "$CGROUP_DIR" 2>/dev/null; then
            echo "kata-prepare: mounted a fresh cgroup2 on $CGROUP_DIR"
            fixed=1
        fi
    fi
    if [ "$fixed" = 0 ] || ! cgroup_writable; then
        echo "kata-prepare: /sys/fs/cgroup is not writable ($CGROUP_DIR); run the image with --runtime kata and the documented flags (see USAGE.md)" >&2
        exit 1
    fi
fi
