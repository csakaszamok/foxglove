#!/bin/sh
set -e

INSTANCE_NAME_FILE=${INSTANCE_NAME_FILE:-/etc/instance/name}
FRPC_CONFIG_DIR=${FRPC_CONFIG_DIR:-/etc/frpc}
FRP_SERVER_ADDR=${FRP_SERVER_ADDR:-frps}
FRP_SERVER_PORT=${FRP_SERVER_PORT:-7000}
# docker-gen renders frpc.tmpl from the environment, so the defaults must be exported
export FRP_SERVER_ADDR FRP_SERVER_PORT

# Validate instance name file
if [ ! -f "$INSTANCE_NAME_FILE" ]; then
    echo "ERROR: Instance name file not found at $INSTANCE_NAME_FILE" >&2
    echo "Mount it with: -v /path/to/name-file:$INSTANCE_NAME_FILE:ro" >&2
    exit 1
fi

INSTANCE_NAME=$(tr -d '[:space:]' < "$INSTANCE_NAME_FILE")
if [ -z "$INSTANCE_NAME" ]; then
    echo "ERROR: Instance name file at $INSTANCE_NAME_FILE is empty" >&2
    exit 1
fi
export INSTANCE_NAME

# Validate required env vars
for var in FRP_TOKEN BASE_DOMAIN; do
    eval val=\$$var
    if [ -z "$val" ]; then
        echo "ERROR: Required environment variable $var is not set" >&2
        exit 1
    fi
done

# Random per-start secret for frpc.tmpl's readiness marker (an stcp proxy
# nobody should ever connect to)
FRPC_READY_SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
export FRPC_READY_SECRET

# Generate initial frpc.toml so frpc can start before docker-gen produces its first run
mkdir -p "$FRPC_CONFIG_DIR"
cat > "$FRPC_CONFIG_DIR/frpc.toml" <<EOF
serverAddr = "${FRP_SERVER_ADDR}"
serverPort = ${FRP_SERVER_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"

webServer.addr = "127.0.0.1"
webServer.port = 7400
EOF

# Prepare sshd host keys. Never fatal: the sandbox must come up regardless.
if [ -x /usr/local/bin/sshd-prepare.sh ]; then
    /usr/local/bin/sshd-prepare.sh || echo "WARNING: sshd preparation failed" >&2
fi

exec supervisord -c /etc/supervisor/conf.d/supervisord.conf
