#!/bin/sh
# claude-cred source transform — runs inside host-sync-worker after
# /src/claude-cred → /dst/claude-cred/claude-cred.
#
# The bound source is the SINGLE file ~/.claude/.credentials.json, never the
# whole ~/.claude directory: settings.json (host hooks), plugins/, skills/,
# projects/, sessions/ and history.jsonl deliberately stay on the host so the
# container's Claude Code starts clean. Reshapes the raw copy into the agent
# home layout the volume actually serves:
#
#   /dst/.claude/.credentials.json   OAuth credential (rewritten in-container
#                                    on token refresh — host copy untouched)
#   /dst/.claude.json                minimal config, onboarding suppressed
#
# Missing/empty credential is a WARNING, not an error: omp is the primary
# engine and paperclip must still come up without a Claude login.
set -eu

RAW=/dst/claude-cred/claude-cred

if [ ! -f "$RAW" ] || [ ! -s "$RAW" ]; then
    echo "WARN: ~/.claude/.credentials.json missing or empty — claude_local will be unavailable (run 'claude' on the host to log in, then scripts/sync-claude-creds.sh)" >&2
    rm -rf /dst/claude-cred
    exit 0
fi

mkdir -p /dst/.claude
cp -a "$RAW" /dst/.claude/.credentials.json
rm -rf /dst/claude-cred

chmod 700 /dst/.claude
chmod 600 /dst/.claude/.credentials.json

# Seeded once, then left alone — Claude Code owns this file at runtime.
# hasCompletedOnboarding suppresses the first-run onboarding gate; nothing
# else is inherited from the host config.
if [ ! -f /dst/.claude.json ]; then
    printf '{"hasCompletedOnboarding":true}\n' > /dst/.claude.json
fi
chmod 600 /dst/.claude.json
