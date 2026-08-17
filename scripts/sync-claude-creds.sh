#!/usr/bin/env bash
# sync-claude-creds.sh — Claude-specific convenience wrapper around the
# generic scripts/host-sync.sh (see docs/superpowers/specs/
# 2026-08-17-host-config-sync-design.md).
#
# The `host-sync-claude` compose one-shot mirrors the credential on every
# `docker compose up` (so `down -v` + `up -d` needs no manual step); this
# wrapper is for manual refresh after the host credential *changes* — most
# often after Claude Code refreshes its OAuth token on the host, or after a
# fresh `claude` login.
#
#   scripts/sync-claude-creds.sh
#
# Prereqs (host side):
#   ~/.claude/.credentials.json   — Claude Code OAuth credential
#
# ONLY that file is copied. settings.json (host hooks), plugins/, skills/,
# projects/, sessions/ and history.jsonl are deliberately left on the host so
# the container's Claude Code stays clean.
#
# Note: Anthropic OAuth refresh tokens are single-use. Whichever side
# refreshes first (host Claude Code, or the container's) invalidates the
# other's copy — re-run this after the container side breaks.
set -euo pipefail
cd "$(dirname "$0")/.."

CRED="${HOME}/.claude/.credentials.json"
if [ ! -s "$CRED" ]; then
    echo "ERROR: $CRED missing or empty — run 'claude' on the host to log in first" >&2
    exit 1
fi

./scripts/host-sync.sh \
    --volume opc-prototyper-home \
    --src claude-cred="$CRED" \
    --hook claude-cred=scripts/hooks/claude-cred.sh
