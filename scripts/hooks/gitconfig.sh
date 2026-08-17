#!/bin/sh
# gitconfig source transform — runs inside host-sync-worker after
# /src/gitconfig → /dst/gitconfig.
#
# Extracts a minimal git identity into the consumer layout
# /creds/git/config ([user] name/email + [init] defaultBranch). The worker's
# raw copy is removed — the volume only carries the extracted form. Include/
# signing/section complexity deliberately not carried.
set -eu

rm -rf /dst/gitconfig
mkdir -p /dst/git

{
    echo "[user]"
    sed -n "/^[[:space:]]*\[user\]/,/^\[/p" /src/gitconfig | grep -E "^[[:space:]]*(name|email)[[:space:]]*=" | head -2 | sed "s/^[[:space:]]*//"
    echo "[init]"
    echo "  defaultBranch = main"
} > /dst/git/config

if ! grep -q "^name" /dst/git/config; then
    echo "WARN: ~/.gitconfig has no [user] name — set git identity in the containers manually" >&2
fi
