#!/bin/sh
# Prepare sshd before supervisord starts it: make sure host keys exist in
# $SSH_HOST_KEY_DIR (p7y mounts a writable dir there so fingerprints persist;
# without a mount they land in the container's own filesystem).
HOST_KEY_DIR=${SSH_HOST_KEY_DIR:-/etc/ssh/host-keys}
FALLBACK_DIR=${SSH_HOST_KEY_FALLBACK_DIR:-/run/ssh-host-keys}
SSHD_CONFIG=${SSHD_CONFIG:-/etc/ssh/sshd_config}
KEY_TYPES="ed25519 rsa ecdsa"

mkdir -p "$HOST_KEY_DIR" || exit 1

for type in $KEY_TYPES; do
    key="$HOST_KEY_DIR/ssh_host_${type}_key"
    if [ ! -s "$key" ]; then
        echo "Generating SSH host key $key"
        rm -f "$key" "$key.pub"
        ssh-keygen -q -t "$type" -N '' -C '' -f "$key" || exit 1
    fi
    chmod 600 "$key" 2>/dev/null
done

# sshd refuses a private key it owns that is group/world accessible. Some
# bind mounts (Docker Desktop on Windows) show 0777 and ignore chmod; serve
# a private copy of the same keys from the container filesystem instead.
key_dir=$HOST_KEY_DIR
for type in $KEY_TYPES; do
    set -- $(stat -c '%u %a' "$HOST_KEY_DIR/ssh_host_${type}_key")
    if [ "$1" = "$(id -u)" ] && [ $(( 0$2 & 077 )) -ne 0 ]; then
        key_dir=$FALLBACK_DIR
    fi
done
if [ "$key_dir" = "$FALLBACK_DIR" ]; then
    echo "SSH host keys in $HOST_KEY_DIR are not private (mode ignored by mount); using a copy in $FALLBACK_DIR"
    mkdir -p "$FALLBACK_DIR" && chmod 700 "$FALLBACK_DIR" || exit 1
    for type in $KEY_TYPES; do
        install -m 600 "$HOST_KEY_DIR/ssh_host_${type}_key" "$FALLBACK_DIR/" || exit 1
    done
fi
sed -i "s|^HostKey .*/\(ssh_host_[a-z0-9]*_key\)\$|HostKey $key_dir/\1|" "$SSHD_CONFIG" || exit 1

/usr/sbin/sshd -t -f "$SSHD_CONFIG"
