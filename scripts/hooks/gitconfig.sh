#!/bin/sh
# gitconfig source transform — runs inside host-sync-worker after
# /src/gitconfig → /dst/gitconfig.
#
# Extracts git identity into /creds/git/config and adds a GitHub-only gh helper.
# The helper reads credentials at invocation time; no token is written here.
# The raw copy is removed; host includes/signing/helpers are not carried.
set -eu

rm -rf /dst/gitconfig
mkdir -p /dst/git

{
    echo "[user]"
    sed -n "/^[[:space:]]*\[user\]/,/^\[/p" /src/gitconfig | grep -E "^[[:space:]]*(name|email)[[:space:]]*=" | head -2 | sed "s/^[[:space:]]*//"
    echo "[init]"
    echo "  defaultBranch = main"
    printf '%s\n' '[credential "https://github.com"]' \
        '  helper =' \
        '  helper = !gh auth git-credential'
} > /dst/git/config

if ! grep -q "^name" /dst/git/config; then
    echo "WARN: ~/.gitconfig has no [user] name — set git identity in the containers manually" >&2
fi
