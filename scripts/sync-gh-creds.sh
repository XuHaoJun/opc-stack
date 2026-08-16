#!/usr/bin/env bash
# Sync host GitHub credentials into the opc-gh-creds named volume shared by
# the paperclip / hermes / frontdoor containers.
#
# The containers mount the volume at /creds and point git/ssh/gh at it via
# env (see opc-gh-seed.sh). Nothing is baked into images; re-run this script
# any time the host credentials change:
#
#   scripts/sync-gh-creds.sh
#
# Prereqs (host side):
#   ~/.ssh          — config + private keys + known_hosts
#   ~/.config/gh    — gh CLI auth state (hosts.yml)
#   ~/.gitconfig    — user.name / user.email (extracted, minimal)
#
# Idempotent. Warns for missing sources and still syncs what exists, but
# exits non-zero so a partial sync is visible.
set -euo pipefail
cd "$(dirname "$0")/.."

# Compose prefixes every named volume with the resolved project name
# (.env COMPOSE_PROJECT_NAME, default "opc"), so the compose key
# "opc-gh-creds" becomes e.g. "opc_opc-gh-creds". Resolve it via compose
# itself; fall back to the env var.
PROJECT="$(docker compose config 2>/dev/null | sed -n 's/^name: *\(.*\)$/\1/p' | head -1)"
[ -n "$PROJECT" ] || PROJECT="${COMPOSE_PROJECT_NAME:-opc}"
VOLUME="${PROJECT}_opc-gh-creds"
IMAGE="alpine:3.20"

MISSING=0

# ── Host-side checks ──
if [ ! -d "${HOME}/.ssh" ]; then
    echo "WARN: ${HOME}/.ssh missing — SSH-based git push will not work" >&2
    MISSING=1
fi
if [ ! -d "${HOME}/.config/gh" ]; then
    echo "WARN: ${HOME}/.config/gh missing — gh CLI not logged in? 'gh repo create' will fail" >&2
    MISSING=1
fi
if [ ! -f "${HOME}/.gitconfig" ]; then
    echo "WARN: ${HOME}/.gitconfig missing — git commits will have no identity" >&2
    MISSING=1
fi

# ── github.com known_hosts (host side; appended only if missing) ──
GITHUB_KNOWN_HOSTS=""
if command -v ssh-keyscan >/dev/null 2>&1; then
    GITHUB_KNOWN_HOSTS="$(ssh-keyscan github.com 2>/dev/null || true)"
fi

# ── Mirror into the volume via a throwaway container (read-only binds) ──
# IdentityFile paths in the ssh config are rewritten from the host layout
# (~/.ssh/x, /home/<u>/.ssh/x, $HOME/.ssh/x) to /creds/ssh/x so the config
# works inside any container regardless of HOME.
BINDS=(-v "${VOLUME}:/creds")
[ -d "${HOME}/.ssh" ]       && BINDS+=(-v "${HOME}/.ssh:/src/ssh:ro")
[ -d "${HOME}/.config/gh" ] && BINDS+=(-v "${HOME}/.config/gh:/src/gh:ro")
[ -f "${HOME}/.gitconfig" ] && BINDS+=(-v "${HOME}/.gitconfig:/src/gitconfig:ro")

if ! docker run --rm -i "${BINDS[@]}" "$IMAGE" sh -eu -c '
    rm -rf /creds/ssh /creds/gh /creds/git
    mkdir -p /creds/ssh /creds/gh /creds/git

    # SSH config + keys + known_hosts
    if [ -d /src/ssh ]; then
        cp -a /src/ssh/. /creds/ssh/
        # Rewrite host-layout path segments (~/.ssh/x, /home/u/.ssh/x,
        # $HOME/.ssh/x) to /creds/ssh/x so the config works in any container
        # regardless of HOME. Applies to IdentityFile, Include, ControlPath…
        sed -i -E "s|[^ ]*/\\.ssh/|/creds/ssh/|g" /creds/ssh/config 2>/dev/null || true
        # If the config never names a key, give github.com the first key found.
        if ! grep -qi "IdentityFile" /creds/ssh/config 2>/dev/null; then
            for k in id_ed25519 id_ecdsa id_rsa; do
                if [ -f "/creds/ssh/$k" ]; then
                    printf "Host github.com\\n  HostName github.com\\n  IdentityFile /creds/ssh/%s\\n  IdentitiesOnly yes\\n" "$k" >> /creds/ssh/config
                    break
                fi
            done
        fi
        # github.com host key (fed via stdin from the host ssh-keyscan).
        if ! grep -q "github.com" /creds/ssh/known_hosts 2>/dev/null; then
            cat >> /creds/ssh/known_hosts
        fi
        # Containers have no ~/.ssh/known_hosts; without an explicit
        # UserKnownHostsFile the pre-seeded keys above are never consulted and
        # ssh falls back to TOFU (or fails in BatchMode). Point every host at
        # the mirrored file; a host config that already names one survives the
        # sed rewrite above and skips this.
        if ! grep -q "UserKnownHostsFile" /creds/ssh/config 2>/dev/null; then
            printf "Host *\\n  UserKnownHostsFile /creds/ssh/known_hosts\\n" >> /creds/ssh/config
        fi
        chmod 700 /creds/ssh
        chmod 600 /creds/ssh/* 2>/dev/null || true
        chmod 644 /creds/ssh/*.pub /creds/ssh/known_hosts /creds/ssh/config 2>/dev/null || true
    fi

    # gh CLI auth state (hosts.yml with token)
    if [ -d /src/gh ]; then
        cp -a /src/gh/. /creds/gh/
    fi

    # Minimal git identity (user.name / user.email only)
    if [ -f /src/gitconfig ]; then
        {
            echo "[user]"
            sed -n "/^[[:space:]]*\[user\]/,/^\[/p" /src/gitconfig | grep -E "^[[:space:]]*(name|email)[[:space:]]*=" | head -2 | sed "s/^[[:space:]]*//"
            echo "[init]"
            echo "  defaultBranch = main"
        } > /creds/git/config
        if ! grep -q "^name" /creds/git/config; then
            echo "WARN: ~/.gitconfig has no [user] name — set git identity in the containers manually" >&2
        fi
    fi
' <<<"${GITHUB_KNOWN_HOSTS}"; then
    echo "ERROR: sync container failed — is the ${VOLUME} volume created? (docker compose up -d first, or docker volume create ${VOLUME})" >&2
    exit 1
fi

echo "OK  synced → ${VOLUME} (mount at /creds in paperclip/hermes/frontdoor)"
if [ "${MISSING}" -ne 0 ]; then
    exit 1
fi
