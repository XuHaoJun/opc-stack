#!/bin/sh
# Generates the relay/owner and front-door agent Nostr keypairs into the
# shared keys volume (idempotent; atomic tmp+mv so concurrent containers
# never read a half-written key).
set -eu

KEYS="${KEYS_DIR:-/keys}"
mkdir -p "$KEYS"

gen() {
    name="$1"
    if [ -f "$KEYS/$name.nsec" ] && [ -f "$KEYS/$name.pub" ]; then
        echo "[keys] $name: already present"
        return 0
    fi
    out="$(/usr/local/bin/buzz-admin generate-key)" || {
        echo "[keys] buzz-admin generate-key failed" >&2
        exit 1
    }
    pub="$(printf '%s\n' "$out" | sed -n 's/^Public key:  //p')"
    sec="$(printf '%s\n' "$out" | sed -n 's/^Secret key:  //p')"
    if [ -z "$pub" ] || [ -z "$sec" ]; then
        echo "[keys] could not parse generate-key output: $out" >&2
        exit 1
    fi
    tmp_pub="$KEYS/.$name.pub.$$"
    tmp_sec="$KEYS/.$name.nsec.$$"
    printf '%s' "$pub" > "$tmp_pub"
    printf '%s' "$sec" > "$tmp_sec"
    chmod 600 "$tmp_sec"
    mv "$tmp_pub" "$KEYS/$name.pub"
    mv "$tmp_sec" "$KEYS/$name.nsec"
    echo "[keys] $name: generated"
}

gen relay
gen agent
echo "[keys] ready"
