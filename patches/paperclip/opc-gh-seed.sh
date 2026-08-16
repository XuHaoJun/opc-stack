#!/bin/sh
# opc-gh-seed.sh — source from an OPC entrypoint.
#
# Points git/ssh/gh at the opc-gh-creds volume (/creds) populated by
# scripts/sync-gh-creds.sh on the host. Env-based so it works for any
# runtime uid (paperclip node/1000, hermes 10000, frontdoor root) without
# guessing HOME. Idempotent; re-fixes key permissions every boot.
opc_gh_seed() {
    if [ ! -d /creds ]; then
        echo "[gh-seed] /creds not mounted — GitHub integration disabled" >&2
        return 0
    fi

    # ssh rejects group/world-readable private keys; self-heal perms.
    chmod 700 /creds/ssh 2>/dev/null || true
    chmod 600 /creds/ssh/id_* 2>/dev/null || true

    # The sync script rewrites IdentityFile paths to /creds/ssh/…, so the
    # whole config works container-side. accept-new covers a missing
    # github.com host key (sync also pre-seeds known_hosts).
    export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -F /creds/ssh/config -o StrictHostKeyChecking=accept-new}"
    export GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-/creds/git/config}"
    export GH_CONFIG_DIR="${GH_CONFIG_DIR:-/creds/gh}"
    export GIT_TERMINAL_PROMPT=0
}
