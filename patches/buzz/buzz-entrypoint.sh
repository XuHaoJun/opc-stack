#!/bin/sh
# Buzz relay entrypoint: seed nix, export the relay/owner identity from the
# shared keys volume, then exec the relay.
set -eu

. /usr/local/bin/opc-nix-seed.sh
opc_nix_seed

if [ -n "${BUZZ_KEYS_DIR:-}" ] && [ -f "${BUZZ_KEYS_DIR}/relay.nsec" ]; then
    export BUZZ_RELAY_PRIVATE_KEY="$(cat "${BUZZ_KEYS_DIR}/relay.nsec")"
    export RELAY_OWNER_PUBKEY="$(cat "${BUZZ_KEYS_DIR}/relay.pub")"
    echo "[buzz] relay identity loaded from ${BUZZ_KEYS_DIR}"
fi

if [ "$#" -gt 0 ]; then
    exec "$@"
fi
exec /usr/local/bin/buzz-relay
