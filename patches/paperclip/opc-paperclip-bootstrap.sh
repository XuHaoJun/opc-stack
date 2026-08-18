#!/bin/sh
# opc-paperclip-bootstrap.sh — one-shot first-boot bootstrap (idempotent).
#
#   1. First admin: sign up (or in) with PAPERCLIP_ADMIN_* creds, then
#      POST /api/bootstrap/claim → that user becomes instance admin.
#   2. Default company (PAPERCLIP_COMPANY_NAME).
#   3. Executor agent (claude_local adapter → `omp acp --yolo`, per AGENTS.md
#      verified handshake config).
#   4. Board API key → /keys/paperclip-api.key (frontdoor/hermes entrypoints
#      export PAPERCLIP_API_KEY from it — no manual .env step).
#   5. Vendored skills (/opt/opc-skills/*) → company skill library.
#   6. Prototyper agent (omp, scoped to the prototype/prototype-workspace/devenv skills).
#
# Re-run reconciles missing pieces only. The key file is the source of truth:
# if it exists, the key is not re-created (the token is only returned once)
# and reconciliation uses it as bearer auth instead of the admin session.
set -eu

API="${PAPERCLIP_API_URL:-http://paperclip:3100}/api"
ORIGIN="${PAPERCLIP_API_URL:-http://paperclip:3100}"
ADMIN_EMAIL="${PAPERCLIP_ADMIN_EMAIL:-admin@opc.local}"
ADMIN_PASSWORD="${PAPERCLIP_ADMIN_PASSWORD:-}"
ADMIN_NAME="${PAPERCLIP_ADMIN_NAME:-Admin}"
COMPANY_NAME="${PAPERCLIP_COMPANY_NAME:-OPC}"
AGENT_NAME="${PAPERCLIP_EXECUTOR_AGENT_NAME:-OMP Engineer}"
PROTOTYPER_NAME="${PAPERCLIP_PROTOTYPER_AGENT_NAME:-Prototyper}"
SKILLS_SRC="${OPC_SKILLS_DIR:-/opt/opc-skills}"
KEY_NAME="${PAPERCLIP_KEY_NAME:-frontdoor}"
JAR=/tmp/pc-cookies.txt

[ -n "$ADMIN_PASSWORD" ] || { echo "PAPERCLIP_ADMIN_PASSWORD is required (set in .env)"; exit 1; }

echo "[pc-bootstrap] waiting for paperclip…"
ok=""
for i in $(seq 1 60); do
    if curl -fsS "${API%/api}/api/health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
done
[ -n "$ok" ] || { echo "[pc-bootstrap] paperclip not healthy after 120s"; exit 1; }

# ── Auth mode: board key (already bootstrapped) vs admin session (first run) ──
if [ -s /keys/paperclip-api.key ]; then
    AUTH_MODE=key
    KEY="$(cat /keys/paperclip-api.key)"
    echo "[pc-bootstrap] using existing board key for reconciliation"
else
    AUTH_MODE=session
fi

api_get() { # path
    if [ "$AUTH_MODE" = key ]; then
        curl -fsS -H "Authorization: Bearer $KEY" "$API$1" 2>/dev/null || true
    else
        curl -fsS -b "$JAR" "$API$1" 2>/dev/null || true
    fi
}

# Body-on-stdin variants: skill payloads embed whole markdown files, which are
# too large and too quote-heavy to pass as a shell argument.
api_post_raw() { # path  (body on stdin)
    if [ "$AUTH_MODE" = key ]; then
        curl -fsS -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
            -H "Origin: $ORIGIN" -X POST "$API$1" --data-binary @- 2>/dev/null || true
    else
        curl -fsS -b "$JAR" -H 'Content-Type: application/json' \
            -H "Origin: $ORIGIN" -X POST "$API$1" --data-binary @- 2>/dev/null || true
    fi
}

api_patch_raw() { # path  (body on stdin)
    if [ "$AUTH_MODE" = key ]; then
        curl -fsS -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
            -H "Origin: $ORIGIN" -X PATCH "$API$1" --data-binary @- 2>/dev/null || true
    else
        curl -fsS -b "$JAR" -H 'Content-Type: application/json' \
            -H "Origin: $ORIGIN" -X PATCH "$API$1" --data-binary @- 2>/dev/null || true
    fi
}

api_post() { # path body
    if [ "$AUTH_MODE" = key ]; then
        curl -fsS -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
            -H "Origin: $ORIGIN" -X POST "$API$1" -d "$2" 2>/dev/null || true
    else
        curl -fsS -b "$JAR" -H 'Content-Type: application/json' \
            -H "Origin: $ORIGIN" -X POST "$API$1" -d "$2" 2>/dev/null || true
    fi
}

# ── 1. First admin (only when no admin exists yet) ──
if [ "$(curl -fsS "${API%/api}/api/health" | jq -r '.bootstrapStatus // "bootstrap_pending"')" = "ready" ]; then
    echo "[pc-bootstrap] instance already bootstrapped; skipping admin claim"
else
    if ! curl -fsS -c "$JAR" -X POST "$API/auth/sign-in/email" \
            -H 'Content-Type: application/json' \
            -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" >/dev/null 2>&1; then
        echo "[pc-bootstrap] sign-in failed; trying sign-up"
        curl -fsS -c "$JAR" -X POST "$API/auth/sign-up/email" \
            -H 'Content-Type: application/json' \
            -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\",\"name\":\"$ADMIN_NAME\"}" >/dev/null \
            || { echo "[pc-bootstrap] sign-up failed"; exit 1; }
    fi

    code="$(curl -sS -b "$JAR" -o /dev/null -w '%{http_code}' -X POST \
        -H "Origin: $ORIGIN" "$API/bootstrap/claim")"
    case "$code" in
        200|409) echo "[pc-bootstrap] first admin: ok ($code)" ;;
        *) echo "[pc-bootstrap] bootstrap/claim failed: HTTP $code"; exit 1 ;;
    esac
fi

# ── 2. Company ──
company_id="$(api_get "/companies" | jq -r '.[0].id // empty' 2>/dev/null)"
if [ -z "$company_id" ]; then
    company_id="$(api_post "/companies" "{\"name\":\"$COMPANY_NAME\"}" | jq -r '.id // empty')"
    [ -n "$company_id" ] || { echo "[pc-bootstrap] company creation failed (auth?)"; exit 1; }
    echo "[pc-bootstrap] created company: $company_id"
else
    echo "[pc-bootstrap] company exists: $company_id"
fi

# ── 3. Executor agent (claude_local → omp acp) ──
agent_id="$(api_get "/companies/$company_id/agents" | \
    jq -r --arg n "$AGENT_NAME" '.[] | select(.name == $n) | .id' 2>/dev/null | head -1)"
if [ -z "$agent_id" ]; then
    agent_id="$(api_post "/companies/$company_id/agents" \
        "{\"name\":\"$AGENT_NAME\",\"adapterType\":\"claude_local\",\"adapterConfig\":{\"engine\":\"acp\",\"agentCommand\":\"omp acp --yolo\"}}" | jq -r '.id // empty')"
    [ -n "$agent_id" ] || { echo "[pc-bootstrap] agent creation failed (auth?)"; exit 1; }
    echo "[pc-bootstrap] created agent: $agent_id"
else
    echo "[pc-bootstrap] agent exists: $agent_id"
fi

# ── 4. Board API key → /keys/paperclip-api.key ──
if [ ! -s /keys/paperclip-api.key ]; then
    token="$(api_post "/board-api-keys" "{\"name\":\"$KEY_NAME\"}" | jq -r '.token // empty')"
    [ -n "$token" ] || { echo "[pc-bootstrap] board key creation failed (auth?)"; exit 1; }
    umask 077
    mkdir -p /keys
    printf '%s\n' "$token" > /keys/paperclip-api.key
    echo "[pc-bootstrap] wrote /keys/paperclip-api.key"
else
    echo "[pc-bootstrap] key file exists; keeping it"
fi

# Second copy inside the paperclip data volume, for container-side tooling
# (`prototype destroy` run by a human via docker exec) that has no
# PAPERCLIP_API_KEY in its environment — only agent runs get one injected.
#
# A copy rather than mounting opc-keys on the paperclip service: that volume
# also holds the buzz relay and agent nsec keys, which paperclip has no
# business being able to read. Spreading one credential beats spreading four.
if [ -d /paperclip ]; then
    mkdir -p /paperclip/.opc
    cp -f /keys/paperclip-api.key /paperclip/.opc/board-api.key
    chmod 700 /paperclip/.opc; chmod 600 /paperclip/.opc/board-api.key
    chown -R node:node /paperclip/.opc 2>/dev/null || true
    echo "[pc-bootstrap] mirrored board key to /paperclip/.opc/board-api.key"
fi

# ── 5. Vendored skills → company library ──
# These are vendored (patches/paperclip/skills/) rather than imported from
# GitHub because Paperclip's importer fetches only SKILL.md, and a skill whose
# SKILL.md dispatches to sibling files (prototype → LOGIC.md / UI.md) arrives
# broken. Created as local skills so every file comes along.
install_skill() {
    _sk_dir="$1"
    _sk_slug="$(basename "$_sk_dir")"
    [ -f "$_sk_dir/SKILL.md" ] || return 0

    _sk_desc="$(sed -n 's/^description: *//p' "$_sk_dir/SKILL.md" | head -1)"

    _sk_id="$(api_get "/companies/$company_id/skills" | \
        jq -r --arg s "$_sk_slug" '.[]? | select(.slug == $s) | .id' 2>/dev/null | head -1)"
    if [ -n "$_sk_id" ]; then
        # Reconcile CONTENT, do not just report existence. The image is the
        # source of truth for these skills; an edit in patches/ that never
        # reaches a running stack is the worst kind of change — the file says
        # one thing and the agent reads another, and nothing surfaces the gap.
        # (This is why routing rules live in a skill at all: they must not
        # diverge. A create-only installer quietly reintroduced that risk.)
        _sk_live="$(api_get "/companies/$company_id/skills/$_sk_id" | jq -r '.markdown // ""')"
        if [ "$_sk_live" = "$(cat "$_sk_dir/SKILL.md")" ]; then
            echo "[pc-bootstrap] skill current: $_sk_slug"
        else
            jq -n --arg d "$_sk_desc" --rawfile m "$_sk_dir/SKILL.md" '{description:$d, markdown:$m}' \
              | api_patch_raw "/companies/$company_id/skills/$_sk_id" >/dev/null \
              && echo "[pc-bootstrap] skill updated: $_sk_slug" \
              || echo "[pc-bootstrap] WARNING skill update failed: $_sk_slug" >&2
        fi
        # Sibling files are pushed unconditionally: the files inventory lags
        # (a known upstream quirk), so comparing before writing is unreliable.
        for _sk_f in "$_sk_dir"/*.md; do
            _sk_base="$(basename "$_sk_f")"
            [ "$_sk_base" = "SKILL.md" ] && continue
            jq -n --arg p "$_sk_base" --rawfile c "$_sk_f" '{path:$p, content:$c}' \
              | api_patch_raw "/companies/$company_id/skills/$_sk_id/files" >/dev/null || true
        done
        return 0
    fi

    _sk_id="$(jq -n --arg n "$_sk_slug" --arg s "$_sk_slug" --arg d "$_sk_desc" \
                    --rawfile m "$_sk_dir/SKILL.md" \
              '{name:$n, slug:$s, description:$d, markdown:$m, sharingScope:"company"}' \
              | api_post_raw "/companies/$company_id/skills" | jq -r '.id // empty')"
    [ -n "$_sk_id" ] || { echo "[pc-bootstrap] skill create failed: $_sk_slug" >&2; return 0; }

    # Sibling files SKILL.md links to. Without these the prototype skill's two
    # branches both dead-end.
    for _sk_f in "$_sk_dir"/*.md; do
        _sk_base="$(basename "$_sk_f")"
        [ "$_sk_base" = "SKILL.md" ] && continue
        jq -n --arg p "$_sk_base" --rawfile c "$_sk_f" '{path:$p, content:$c}' \
          | api_patch_raw "/companies/$company_id/skills/$_sk_id/files" >/dev/null || true
    done
    echo "[pc-bootstrap] installed skill: $_sk_slug ($_sk_id)"
}

if [ -d "$SKILLS_SRC" ]; then
    for d in "$SKILLS_SRC"/*/; do
        [ -d "$d" ] && install_skill "${d%/}"
    done
fi

# ── 6. Prototyper agent (omp; scoped skills) ──
# HOME is deliberately NOT overridden: omp reads its model config from
# $HOME/.omp, so pointing HOME at the Claude credential home would break it.
# Skills are per-agent — the executor agent declares no paperclipSkillSync and
# therefore sees none of this.
PROTOTYPER_SKILLS='["prototype","prototype-workspace","devenv"]'
proto_id="$(api_get "/companies/$company_id/agents" | \
    jq -r --arg n "$PROTOTYPER_NAME" '.[]? | select(.name == $n) | .id' 2>/dev/null | head -1)"
if [ -z "$proto_id" ]; then
    proto_id="$(api_post "/companies/$company_id/agents" \
        "{\"name\":\"$PROTOTYPER_NAME\",\"adapterType\":\"claude_local\",\"adapterConfig\":{\"engine\":\"acp\",\"agentCommand\":\"omp acp --yolo\",\"paperclipSkillSync\":{\"desiredSkills\":$PROTOTYPER_SKILLS}}}" \
        | jq -r '.id // empty')"
    [ -n "$proto_id" ] && echo "[pc-bootstrap] created agent: $PROTOTYPER_NAME ($proto_id)" \
                       || echo "[pc-bootstrap] prototyper creation failed" >&2
else
    # Reconcile the skill list on an EXISTING agent. Without this, adding a
    # skill to the image only reaches agents created after that point — the
    # long-lived stack would silently keep the list it was born with. Only the
    # desiredSkills key is touched; everything else the operator changed on the
    # board (model, prompt, env) is preserved.
    proto_cfg="$(api_get "/companies/$company_id/agents" \
        | jq -c --arg n "$PROTOTYPER_NAME" '.[]? | select(.name == $n) | .adapterConfig // {}' | head -1)"
    want="$(printf '%s' "$proto_cfg" | jq -c --argjson s "$PROTOTYPER_SKILLS" \
        '.paperclipSkillSync = ((.paperclipSkillSync // {}) | .desiredSkills = $s)')"
    if [ "$(printf '%s' "$proto_cfg" | jq -cS .)" != "$(printf '%s' "$want" | jq -cS .)" ]; then
        printf '%s' "$(jq -nc --argjson c "$want" '{adapterConfig:$c}')" \
            | api_patch_raw "/agents/$proto_id" >/dev/null \
            && echo "[pc-bootstrap] agent $PROTOTYPER_NAME: skills reconciled → $PROTOTYPER_SKILLS" \
            || echo "[pc-bootstrap] WARNING could not reconcile $PROTOTYPER_NAME skills" >&2
    else
        echo "[pc-bootstrap] agent exists: $PROTOTYPER_NAME (skills current)"
    fi
fi

echo "[pc-bootstrap] done. admin=$ADMIN_EMAIL company=$company_id agent=$AGENT_NAME"
