#!/bin/sh
# opc-issue-watcher.sh — watch a Paperclip issue and post its outcome to a
# Buzz channel as the frontdoor agent.
#
# Modes:
#   opc-issue-watcher.sh <issue-id> <channel-uuid>   # poll until terminal
#   opc-issue-watcher.sh sweep                       # re-attach after restart
#
# Terminal states: done (post GitHub link from comments) / cancelled / blocked
# (post outcome). On a long-running issue (WATCHER_MAX_AGE, default 24h) a
# status note is posted and polling stops. Spawned by the frontdoor agent
# when it creates a ticket, and by the frontdoor entrypoint boot sweep.
set -eu

# The agent's terminal tool spawns children with a sanitized env: the nix
# profile bin (jq), the buzz relay identity, and sometimes the paperclip key
# are missing. Self-heal from known locations (same sources the entrypoints
# use) so the watcher works no matter who spawns it.
export PATH="/nix/var/nix/profiles/per-user/root/profile/bin:$PATH"
if [ -z "${PAPERCLIP_API_KEY:-}" ] && [ -f /keys/paperclip-api.key ]; then
    export PAPERCLIP_API_KEY="$(cat /keys/paperclip-api.key)"
fi
if [ -z "${BUZZ_PRIVATE_KEY:-}" ] && [ -f "${BUZZ_KEYS_DIR:-/keys}/agent.nsec" ]; then
    export BUZZ_PRIVATE_KEY="$(cat "${BUZZ_KEYS_DIR:-/keys}/agent.nsec")"
fi
if [ -z "${BUZZ_RELAY_URL:-}" ]; then
    if [ -f /opt/data/buzz-relay-url ]; then
        export BUZZ_RELAY_URL="$(cat /opt/data/buzz-relay-url)"
    else
        export BUZZ_RELAY_URL="ws://localhost:3000"
    fi
fi

API="${PAPERCLIP_API_URL:-http://paperclip:3100}/api"
AUTH="Authorization: Bearer ${PAPERCLIP_API_KEY:-}"
STATE_DIR="${WATCHER_STATE_DIR:-/opt/data/issue-watchers}"
MAX_AGE="${WATCHER_MAX_AGE:-86400}"
POLL="${WATCHER_POLL_INTERVAL:-60}"
LOG="${WATCHER_LOG:-${STATE_DIR}/watcher.log}"

log() { echo "[$(date -u +%FT%TZ)][watcher] $*" >> "$LOG" 2>/dev/null || echo "[watcher] $*" >&2; }

# post <content> — send to the buzz channel with the frontdoor agent identity
post() {
    if [ -n "${BUZZ_PRIVATE_KEY:-}" ] && [ -n "${BUZZ_RELAY_URL:-}" ]; then
        if buzz messages send --channel "$CHANNEL" --content "$1" >/dev/null 2>&1; then
            log "posted to $CHANNEL: $1"
        else
            log "buzz post FAILED to $CHANNEL: $1"
        fi
    else
        log "no buzz identity (BUZZ_PRIVATE_KEY/RELAY_URL unset); would post: $1"
    fi
}

# api_get <path> — GET with bearer auth; empty string on any failure
api_get() {
    curl -fsS --max-time 15 -H "$AUTH" "$API$1" 2>/dev/null || true
}

# find_github_url <issue-id> — first repo-root GitHub URL in comments
# (skips PR/tree/commit/issue/blob links; the analysis comments contain lots
# of github.com noise, so match a strict repo URL and filter).
find_github_url() {
    api_get "/issues/$1/comments" | \
        jq -r '.. | strings? | select(test("https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"))' 2>/dev/null | \
        grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | \
        grep -vE '/tree/|/pull/|/commit/|/issues/|/blob/|/actions/|/releases/' | \
        head -1
}

# find_channel <issue-id> — BUZZ_CHANNEL marker from comments
find_channel() {
    api_get "/issues/$1/comments" | jq -r '.. | strings? | select(test("BUZZ_CHANNEL:"))' 2>/dev/null | sed -n 's/.*BUZZ_CHANNEL:[[:space:]]*\([0-9a-fA-F-]\{1,64\}\).*/\1/p' | head -1
}

# poll_once <issue-id> → exit 0 when terminal (posting outcome), else continue
poll_once() {
    local id="$1" json status title url
    json="$(api_get "/issues/$id")"
    [ -n "$json" ] || { log "issue $id: GET failed (paperclip down?)"; return 1; }
    status="$(printf '%s' "$json" | jq -r '.status // empty' 2>/dev/null)"
    # jq slices by codepoints — cut -c would split UTF-8 mid-byte (busybox)
    title="$(printf '%s' "$json" | jq -r '(.title // .id // "issue")[0:80]' 2>/dev/null)"

    case "$status" in
        done)
            url="$(find_github_url "$id")"
            if [ -n "$url" ]; then
                post "✅ ${title} 完成: ${url}"
            else
                post "✅ ${title} 完成 (ticket 無 GitHub link, 見 paperclip)"
            fi
            touch "$STATE_DIR/$id.posted" 2>/dev/null || true
            return 0
            ;;
        cancelled|blocked)
            post "⚠️ ${title} 已終止 (status=${status})"
            touch "$STATE_DIR/$id.posted" 2>/dev/null || true
            return 0
            ;;
        *) return 1 ;;
    esac
}

watch() {
    local ISSUE_ID="$1" start now
    CHANNEL="$2"
    mkdir -p "$STATE_DIR"
    start="$(date +%s)"
    while :; do
        if poll_once "$ISSUE_ID"; then
            rm -f "$STATE_DIR/$ISSUE_ID.pid"
            exit 0
        fi
        now="$(date +%s)"
        if [ $((now - start)) -gt "$MAX_AGE" ]; then
            title="$(api_get "/issues/$ISSUE_ID" | jq -r '.title // "issue"' 2>/dev/null | cut -c1-80)"
            post "⏳ ${title} 超過 ${MAX_AGE}s 仍在進行 — 檢查 paperclip ticket"
            rm -f "$STATE_DIR/$ISSUE_ID.pid"
            exit 0
        fi
        sleep "$POLL"
    done
}

# sweep — scan open issues for BUZZ_CHANNEL markers without a live watcher
sweep() {
    mkdir -p "$STATE_DIR"
    local company issues ids id channel pid
    # Agent API keys answer /agents/me; board keys list /companies.
    company="$(api_get "/agents/me" | jq -r '.companyId // .company_id // empty' 2>/dev/null)"
    [ -n "$company" ] || company="$(api_get "/companies" | jq -r '.[0].id // empty' 2>/dev/null)"
    [ -n "$company" ] || { log "sweep: no company resolvable (auth?)"; exit 1; }
    issues="$(api_get "/companies/$company/issues")"
    # Scan ALL issues (not just open): a ticket that completed while the
    # container was down still needs its delivery. .posted marks delivered.
    ids="$(printf '%s' "$issues" | jq -r '
        if type == "array" then .[]
        elif .issues != null then .issues[]
        elif .data != null then .data[]
        else empty end
        | .id' 2>/dev/null)"
    for id in $ids; do
        channel="$(find_channel "$id")"
        [ -n "$channel" ] || continue
        [ -f "$STATE_DIR/$id.posted" ] && continue
        if [ -f "$STATE_DIR/$id.pid" ]; then
            pid="$(cat "$STATE_DIR/$id.pid" 2>/dev/null || true)"
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                continue  # already watched
            fi
            rm -f "$STATE_DIR/$id.pid"
        fi
        log "sweep: re-attaching watcher for $id → $channel"
        nohup "$0" "$id" "$channel" >> "$LOG" 2>&1 &
    done
    log "sweep: done"
}

case "${1:-}" in
    sweep) sweep ;;
    "") echo "usage: $0 <issue-id> <channel-uuid> | $0 sweep" >&2; exit 2 ;;
    *) watch "$1" "${2:-}" ;;
esac
