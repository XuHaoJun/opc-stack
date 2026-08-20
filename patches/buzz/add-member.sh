#!/bin/sh
# One-shot bootstrap: waits for the relay, then grants the front-door agent
# pubkey relay membership (idempotent). Runs with the owner identity.
set -eu

export BUZZ_RELAY_PRIVATE_KEY="$(cat "${KEYS_DIR:-/keys}/relay.nsec")"
export RELAY_OWNER_PUBKEY="$(cat "${KEYS_DIR:-/keys}/relay.pub")"
# buzz-admin reads RELAY_URL (not BUZZ_RELAY_URL) for tenant resolution.
_canonical="${BUZZ_RELAY_URL:-ws://localhost:3000}"
export RELAY_URL="${RELAY_ADMIN_URL:-http://$(printf '%s' "$_canonical" | sed 's#^wss\?://##')}"
export BUZZ_RELAY_URL="$_canonical"

ready=""
for _ in $(seq 1 120); do
    if curl -fsS "http://buzz:8080/_readiness" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
[ -n "$ready" ] || { echo "[bootstrap] relay never became ready" >&2; exit 1; }

# Every agent identity that posts to the relay needs membership. Loop rather
# than repeat: adding the next expert is one filename.
for _who in agent scientist; do
    _pub="${KEYS_DIR:-/keys}/$_who.pub"
    [ -s "$_pub" ] || { echo "[bootstrap] no $_who.pub — skipping"; continue; }
    /usr/local/bin/buzz-admin add-member --pubkey "$(cat "$_pub")" --role member
    echo "[bootstrap] $_who is a relay member"
done
