#!/bin/sh
MAX_RETRIES=3
RETRY_DELAY=${RETRY_DELAY:-2}
attempt=0

while [ $attempt -lt $MAX_RETRIES ]; do
    attempt=$((attempt + 1))
    if frpc reload -c /etc/frpc/frpc.toml 2>&1; then
        echo "frpc reloaded successfully (attempt $attempt)"
        exit 0
    fi
    if [ $attempt -lt $MAX_RETRIES ]; then
        echo "frpc reload failed (attempt $attempt/$MAX_RETRIES), retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
    fi
done

echo "ERROR: frpc reload failed after $MAX_RETRIES attempts" >&2
exit 1
