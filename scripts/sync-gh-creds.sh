#!/usr/bin/env bash
# sync-gh-creds.sh — gh-specific convenience wrapper around the generic
# scripts/host-sync.sh (see docs/superpowers/specs/2026-08-17-host-config-sync-design.md).
#
# The `host-sync` compose one-shot mirrors host creds on every `docker
# compose up` (so `down -v` + `up -d` needs no manual step); this wrapper is
# for manual refresh after host credential *changes* (new key, `gh auth
# login`, gitconfig edit) — it additionally feeds fresh `ssh-keyscan
# github.com` output through stdin to the ssh hook.
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

GITHUB_KNOWN_HOSTS=""
if command -v ssh-keyscan >/dev/null 2>&1; then
    GITHUB_KNOWN_HOSTS="$(ssh-keyscan github.com 2>/dev/null || true)"
fi

printf '%s' "${GITHUB_KNOWN_HOSTS}" | ./scripts/host-sync.sh \
    --volume opc-gh-creds \
    --src ssh="${HOME}/.ssh" \
    --src gh="${HOME}/.config/gh" \
    --src gitconfig="${HOME}/.gitconfig" \
    --hook ssh=scripts/hooks/ssh.sh \
    --hook gitconfig=scripts/hooks/gitconfig.sh
