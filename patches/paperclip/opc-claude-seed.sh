#!/bin/sh
# opc-claude-seed.sh — source from the paperclip entrypoint.
#
# Hands the prototyper agent's home volume to the `node` runtime user. The
# volume is populated by the `host-sync-claude` compose one-shot with ONLY
# ~/.claude/.credentials.json (see scripts/hooks/claude-cred.sh) — the rest
# of the host's ~/.claude (settings/hooks, plugins, skills, projects,
# history) is deliberately left behind so this Claude is clean.
#
# Must be writable: Claude Code rewrites .credentials.json on OAuth refresh.
# That write lands in the volume, never on the host — but Anthropic refresh
# tokens are single-use, so a refresh here invalidates the host's copy. Fix
# by re-running scripts/sync-claude-creds.sh after logging in again.
#
# Absent volume / absent credential is not an error: omp is the primary
# engine and paperclip must come up either way.
opc_claude_seed() {
    _ph="${OPC_PROTOTYPER_HOME:-/agent-homes/prototyper}"

    [ -d "$_ph" ] || return 0

    chown -R node:node "$_ph" 2>/dev/null || true
    chmod 700 "$_ph" 2>/dev/null || true
    chmod 700 "$_ph/.claude" 2>/dev/null || true
    chmod 600 "$_ph/.claude/.credentials.json" 2>/dev/null || true
    chmod 600 "$_ph/.claude.json" 2>/dev/null || true

    if [ -f "$_ph/.claude/.credentials.json" ]; then
        echo "[claude-seed] prototyper home ready at $_ph (Claude credential present)"
    else
        echo "[claude-seed] no Claude credential in $_ph — claude_local unavailable (omp unaffected)" >&2
    fi
}
