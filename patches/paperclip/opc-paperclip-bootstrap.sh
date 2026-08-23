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
#   7. Scientist agent (hermes_gateway adapter → the gateway's agt-scientist profile).
#
# Re-run reconciles bootstrap-owned state. The key file is the source of truth:
# if it exists, the key is not re-created (the token is only returned once)
# and reconciliation uses it as bearer auth instead of the admin session.
set -eu

API="${PAPERCLIP_API_URL:-http://paperclip:3100}/api"
ORIGIN="${PAPERCLIP_API_URL:-http://paperclip:3100}"
ADMIN_EMAIL="${PAPERCLIP_ADMIN_EMAIL:-admin@opc.local}"
ADMIN_PASSWORD="${PAPERCLIP_ADMIN_PASSWORD:-}"
ADMIN_NAME="${PAPERCLIP_ADMIN_NAME:-Admin}"
COMPANY_NAME="${PAPERCLIP_COMPANY_NAME:-OPC}"
DEFAULT_EXECUTOR_NAME="Fullstack Engineer"
LEGACY_EXECUTOR_NAME="OMP Engineer"
case "${PAPERCLIP_EXECUTOR_AGENT_NAME:-}" in
    ""|"$LEGACY_EXECUTOR_NAME") AGENT_NAME="$DEFAULT_EXECUTOR_NAME" ;;
    *) AGENT_NAME="$PAPERCLIP_EXECUTOR_AGENT_NAME" ;;
esac
PROTOTYPER_NAME="${PAPERCLIP_PROTOTYPER_AGENT_NAME:-Prototyper}"
SCIENTIST_NAME="${PAPERCLIP_SCIENTIST_AGENT_NAME:-Scientist}"
SKILLS_SRC="${OPC_SKILLS_DIR:-/opt/opc-skills}"
FULLSTACK_PROMPT="/opt/opc-agent-prompts/fullstack-engineer.md"
PROTOTYPER_PROMPT="/opt/opc-agent-prompts/prototyper.md"
KEY_NAME="${PAPERCLIP_KEY_NAME:-frontdoor}"
FULLSTACK_MAX_CONCURRENT_RUNS_DEFAULT=4
FULLSTACK_MAX_CONCURRENT_RUNS_UPSTREAM_DEFAULT=20

opc_managed_concurrency_action() { # current marker default
    _omca_current="$1"
    _omca_marker="$2"
    _omca_default="$3"
    if [ -z "$_omca_marker" ]; then
        case "$_omca_current" in
            "$FULLSTACK_MAX_CONCURRENT_RUNS_UPSTREAM_DEFAULT"|\
            "$_omca_default") printf '%s\n' apply ;;
            *) printf '%s\n' preserve ;;
        esac
    elif [ "$_omca_current" = "$_omca_marker" ]; then
        if [ "$_omca_marker" = "$_omca_default" ]; then
            printf '%s\n' keep
        else
            printf '%s\n' apply
        fi
    else
        printf '%s\n' preserve
    fi
}
if [ "${OPC_PAPERCLIP_BOOTSTRAP_LIB_ONLY:-0}" = 1 ]; then
    return 0 2>/dev/null || exit 0
fi

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

api_put_raw() { # path  (body on stdin)
    if [ "$AUTH_MODE" = key ]; then
        curl -fsS -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
            -H "Origin: $ORIGIN" -X PUT "$API$1" --data-binary @- 2>/dev/null || true
    else
        curl -fsS -b "$JAR" -H 'Content-Type: application/json' \
            -H "Origin: $ORIGIN" -X PUT "$API$1" --data-binary @- 2>/dev/null || true
    fi
}


reconcile_agent_instructions() { # agent-id source-file
    _rai_id="$1"
    _rai_source="$2"

    if [ ! -f "$_rai_source" ] || [ ! -r "$_rai_source" ]; then
        echo "[pc-bootstrap] WARNING agent instructions source unavailable: $_rai_source" >&2
        return 1
    fi

    _rai_live_json="$(api_get "/agents/$_rai_id/instructions-bundle/file?path=AGENTS.md")"
    _rai_detail_json="$(api_get "/agents/$_rai_id")"
    _rai_want="$(jq -Rs . < "$_rai_source")"
    if printf '%s' "$_rai_live_json" \
         | jq -e '.path == "AGENTS.md" and (.content | type == "string")' >/dev/null 2>&1 \
       && printf '%s' "$_rai_detail_json" \
         | jq -e '.adapterConfig
                   | type == "object"
                     and (has("promptTemplate") | not)
                     and (has("bootstrapPromptTemplate") | not)' >/dev/null 2>&1; then
        _rai_live="$(printf '%s' "$_rai_live_json" | jq -c '.content')"
        if [ "$_rai_live" = "$_rai_want" ]; then
            echo "[pc-bootstrap] agent instructions current: $_rai_id"
            return 0
        fi
    fi

    if jq -n --arg p AGENTS.md --rawfile c "$_rai_source" \
         '{path:$p, content:$c, clearLegacyPromptTemplate:true}' \
         | api_put_raw "/agents/$_rai_id/instructions-bundle/file" \
         | jq -e '.path == "AGENTS.md"' >/dev/null 2>&1; then
        echo "[pc-bootstrap] agent instructions reconciled: $_rai_id"
        return 0
    fi

    echo "[pc-bootstrap] WARNING could not reconcile AGENTS.md for agent $_rai_id" >&2
    return 1
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

# ── 2. Instance experimental features ──
_experimental_live="$(api_get "/instance/settings/experimental")"
if ! printf '%s' "$_experimental_live" \
    | jq -e '.enableIsolatedWorkspaces == true' >/dev/null 2>&1; then
    _experimental_response="$(jq -nc \
        '{enableIsolatedWorkspaces:true}' \
        | api_patch_raw "/instance/settings/experimental")"
    if ! printf '%s' "$_experimental_response" \
        | jq -e '.enableIsolatedWorkspaces == true' >/dev/null 2>&1; then
        echo "[pc-bootstrap] isolated workspaces enable failed" >&2
        exit 1
    fi
fi
_experimental_live="$(api_get "/instance/settings/experimental")"
if ! printf '%s' "$_experimental_live" \
    | jq -e '.enableIsolatedWorkspaces == true' >/dev/null 2>&1; then
    echo "[pc-bootstrap] isolated workspaces verification failed" >&2
    exit 1
fi
echo "[pc-bootstrap] instance isolated workspaces: enabled/current"

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
EXECUTOR_ROLE="engineer"
EXECUTOR_TITLE="Fullstack Engineer"
EXECUTOR_CAPABILITIES="Implements and maintains durable production systems."

_agents_json="$(api_get "/companies/$company_id/agents")"
if ! printf '%s' "$_agents_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "[pc-bootstrap] executor lookup failed" >&2
    exit 1
fi

_desired_agent_id="$(printf '%s' "$_agents_json" | \
    jq -r --arg n "$AGENT_NAME" '.[] | select(.name == $n) | .id' 2>/dev/null | head -1)"
_legacy_agent_id=""
if [ "$AGENT_NAME" = "$DEFAULT_EXECUTOR_NAME" ]; then
    _legacy_agent_id="$(printf '%s' "$_agents_json" | \
        jq -r --arg n "$LEGACY_EXECUTOR_NAME" '.[] | select(.name == $n) | .id' 2>/dev/null | head -1)"
fi

if [ -n "$_desired_agent_id" ] && [ -n "$_legacy_agent_id" ]; then
    echo "[pc-bootstrap] FATAL executor identity collision: both '$DEFAULT_EXECUTOR_NAME' and '$LEGACY_EXECUTOR_NAME' exist" >&2
    exit 1
fi

agent_id="$_desired_agent_id"
if [ -z "$agent_id" ] && [ -n "$_legacy_agent_id" ]; then
    agent_id="$_legacy_agent_id"
    _rename_response="$(jq -nc \
        --arg n "$DEFAULT_EXECUTOR_NAME" \
        --arg r "$EXECUTOR_ROLE" \
        --arg t "$EXECUTOR_TITLE" \
        --arg c "$EXECUTOR_CAPABILITIES" \
        '{name:$n, role:$r, title:$t, capabilities:$c}' \
        | api_patch_raw "/agents/$agent_id")"
    if ! printf '%s' "$_rename_response" | jq -e \
         --arg id "$agent_id" --arg n "$DEFAULT_EXECUTOR_NAME" \
         '.id == $id and .name == $n' >/dev/null 2>&1; then
        echo "[pc-bootstrap] executor rename failed: $LEGACY_EXECUTOR_NAME ($agent_id)" >&2
        exit 1
    fi
    echo "[pc-bootstrap] renamed executor: $LEGACY_EXECUTOR_NAME -> $DEFAULT_EXECUTOR_NAME ($agent_id)"
fi

if [ -z "$agent_id" ]; then
    _create_response="$(jq -nc \
        --arg n "$AGENT_NAME" \
        --arg r "$EXECUTOR_ROLE" \
        --arg t "$EXECUTOR_TITLE" \
        --arg c "$EXECUTOR_CAPABILITIES" \
        '{name:$n, role:$r, title:$t, capabilities:$c,
          adapterType:"claude_local",
          adapterConfig:{engine:"acp", agentCommand:"omp acp --yolo"},
          runtimeConfig:{heartbeat:{maxConcurrentRuns:4}},
          metadata:{opcManagedDefaults:{fullstackMaxConcurrentRuns:4}}}' \
        | api_post_raw "/companies/$company_id/agents")"
    agent_id="$(printf '%s' "$_create_response" | jq -r '.id // empty')"
    if [ -z "$agent_id" ] || ! printf '%s' "$_create_response" | jq -e \
         --arg id "$agent_id" --arg n "$AGENT_NAME" \
         --arg r "$EXECUTOR_ROLE" --arg t "$EXECUTOR_TITLE" --arg c "$EXECUTOR_CAPABILITIES" \
         '.id == $id and .name == $n and .role == $r and .title == $t and .capabilities == $c' \
         >/dev/null 2>&1; then
        echo "[pc-bootstrap] executor creation failed" >&2
        exit 1
    fi
    echo "[pc-bootstrap] created agent: $agent_id"
else
    _executor_live="$(api_get "/companies/$company_id/agents" | \
        jq -c --arg id "$agent_id" '.[]? | select(.id == $id)' 2>/dev/null | head -1)"
    if ! printf '%s' "$_executor_live" | jq -e --arg id "$agent_id" '.id == $id' >/dev/null 2>&1; then
        echo "[pc-bootstrap] executor reconciliation lookup failed: $agent_id" >&2
        exit 1
    fi
    if printf '%s' "$_executor_live" | jq -e \
         --arg r "$EXECUTOR_ROLE" --arg t "$EXECUTOR_TITLE" --arg c "$EXECUTOR_CAPABILITIES" \
         '.role == $r and .title == $t and .capabilities == $c' >/dev/null 2>&1; then
        echo "[pc-bootstrap] agent exists: $agent_id (identity current)"
    else
        _executor_response="$(jq -nc \
            --arg r "$EXECUTOR_ROLE" --arg t "$EXECUTOR_TITLE" --arg c "$EXECUTOR_CAPABILITIES" \
            '{role:$r, title:$t, capabilities:$c}' \
            | api_patch_raw "/agents/$agent_id")"
        if ! printf '%s' "$_executor_response" | jq -e \
             --arg id "$agent_id" --arg n "$AGENT_NAME" \
             --arg r "$EXECUTOR_ROLE" --arg t "$EXECUTOR_TITLE" --arg c "$EXECUTOR_CAPABILITIES" \
             '.id == $id and .name == $n and .role == $r and .title == $t and .capabilities == $c' \
             >/dev/null 2>&1; then
            echo "[pc-bootstrap] executor metadata reconciliation failed: $agent_id" >&2
            exit 1
        fi
        echo "[pc-bootstrap] executor metadata reconciled: $agent_id"
    fi
fi

_executor_live="$(api_get "/companies/$company_id/agents" | \
    jq -c --arg id "$agent_id" '.[]? | select(.id == $id)' 2>/dev/null | head -1)"
if ! printf '%s' "$_executor_live" | jq -e --arg id "$agent_id" '.id == $id' >/dev/null 2>&1; then
    echo "[pc-bootstrap] executor concurrency lookup failed: $agent_id" >&2
    exit 1
fi
_executor_current="$(printf '%s' "$_executor_live" | \
    jq -r '.runtimeConfig.heartbeat.maxConcurrentRuns // empty')"
_executor_marker="$(printf '%s' "$_executor_live" | \
    jq -r '.metadata.opcManagedDefaults.fullstackMaxConcurrentRuns // empty')"
_executor_action="$(opc_managed_concurrency_action \
    "$_executor_current" "$_executor_marker" "$FULLSTACK_MAX_CONCURRENT_RUNS_DEFAULT")"
if [ "$_executor_action" = apply ]; then
    _new_runtime="$(printf '%s' "$_executor_live" | jq \
        --argjson n "$FULLSTACK_MAX_CONCURRENT_RUNS_DEFAULT" '
        (.runtimeConfig // {}) as $r
        | $r * {heartbeat:(($r.heartbeat // {})
          * {maxConcurrentRuns:$n})}
        | if ((.modelProfiles // {}) | type == "object")
             and ((.modelProfiles.cheap // {}) | type == "object")
             and ((.modelProfiles.cheap.adapterConfig? | type) != "object")
          then .modelProfiles.cheap.adapterConfig = {}
          else .
          end
    ')"
    _new_metadata="$(printf '%s' "$_executor_live" | jq \
        --argjson n "$FULLSTACK_MAX_CONCURRENT_RUNS_DEFAULT" '
        (.metadata // {}) as $m
        | $m * {opcManagedDefaults:(($m.opcManagedDefaults // {})
          * {fullstackMaxConcurrentRuns:$n})}
    ')"
    _executor_response="$(jq -nc \
        --argjson runtime "$_new_runtime" --argjson metadata "$_new_metadata" \
        '{runtimeConfig:$runtime, metadata:$metadata}' \
        | api_patch_raw "/agents/$agent_id")"
    if ! printf '%s' "$_executor_response" | jq -e \
        --argjson n "$FULLSTACK_MAX_CONCURRENT_RUNS_DEFAULT" \
        '.runtimeConfig.heartbeat.maxConcurrentRuns == $n
         and .metadata.opcManagedDefaults.fullstackMaxConcurrentRuns == $n' \
        >/dev/null 2>&1; then
        echo "[pc-bootstrap] executor concurrency reconciliation failed: $agent_id" >&2
        exit 1
    fi
fi
_executor_live="$(api_get "/companies/$company_id/agents" | \
    jq -c --arg id "$agent_id" '.[]? | select(.id == $id)' 2>/dev/null | head -1)"
if ! printf '%s' "$_executor_live" | jq -e \
    --arg id "$agent_id" \
    '.id == $id and (.runtimeConfig.heartbeat.maxConcurrentRuns | type == "number")' \
    >/dev/null 2>&1; then
    echo "[pc-bootstrap] executor concurrency verification failed: $agent_id" >&2
    exit 1
fi
echo "[pc-bootstrap] executor concurrency: $_executor_action ($agent_id)"


reconcile_agent_instructions "$agent_id" "$FULLSTACK_PROMPT" || true

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
push_skill_siblings() { # skill-dir  skill-id
    for _sib_f in "$1"/*.md; do
        _sib_base="$(basename "$_sib_f")"
        [ "$_sib_base" = "SKILL.md" ] && continue
        jq -n --arg p "$_sib_base" --rawfile c "$_sib_f" '{path:$p, content:$c}' \
          | api_patch_raw "/companies/$company_id/skills/$2/files" \
          | jq -e '.path? // empty' >/dev/null 2>&1 \
          || echo "[pc-bootstrap] WARNING skill file push failed: $(basename "$1")/$_sib_base" >&2
    done
}

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
        #
        # Content goes through PATCH .../files — NOT through PATCH on the skill
        # itself. `updateSkill` accepts a `markdown` key and silently drops it
        # (it writes only name/description/categories/sharing), so that call
        # returns 200 with the old text still on the board. `updateFile` with
        # path SKILL.md is the real path: it rewrites the file on disk and the
        # markdown column, re-derives name/description from the frontmatter,
        # and cuts a version. Two skills sat several commits stale behind that
        # 200 — the exact failure this reconcile exists to prevent, which is
        # why the write is now verified instead of `&&`-chained onto a curl
        # that can never fail (api_patch_raw ends in `|| true`).
        _sk_live="$(api_get "/companies/$company_id/skills/$_sk_id" | jq -r '.markdown // ""')"
        if [ "$_sk_live" = "$(cat "$_sk_dir/SKILL.md")" ]; then
            echo "[pc-bootstrap] skill current: $_sk_slug"
        else
            if jq -n --arg p SKILL.md --rawfile c "$_sk_dir/SKILL.md" '{path:$p, content:$c}' \
                 | api_patch_raw "/companies/$company_id/skills/$_sk_id/files" \
                 | jq -e '.path? // empty' >/dev/null 2>&1; then
                echo "[pc-bootstrap] skill updated: $_sk_slug"
            else
                echo "[pc-bootstrap] WARNING skill update failed: $_sk_slug" >&2
            fi
        fi
        # Sibling files are pushed unconditionally: the files inventory lags
        # (a known upstream quirk), so comparing before writing is unreliable.
        push_skill_siblings "$_sk_dir" "$_sk_id"
        return 0
    fi

    _sk_id="$(jq -n --arg n "$_sk_slug" --arg s "$_sk_slug" --arg d "$_sk_desc" \
                    --rawfile m "$_sk_dir/SKILL.md" \
              '{name:$n, slug:$s, description:$d, markdown:$m, sharingScope:"company"}' \
              | api_post_raw "/companies/$company_id/skills" | jq -r '.id // empty')"
    [ -n "$_sk_id" ] || { echo "[pc-bootstrap] skill create failed: $_sk_slug" >&2; return 0; }

    # Sibling files SKILL.md links to. Without these the prototype skill's two
    # branches both dead-end.
    push_skill_siblings "$_sk_dir" "$_sk_id"
    echo "[pc-bootstrap] installed skill: $_sk_slug ($_sk_id)"
}

if [ -d "$SKILLS_SRC" ]; then
    for d in "$SKILLS_SRC"/*/; do
        [ -d "$d" ] && install_skill "${d%/}"
    done
fi

# ── reconcile_agent <display-name> <adapterType> <desired-config-fn> ──
#
# Create when absent; otherwise merge the desired keys over the live
# adapterConfig and PATCH only on a real difference. The merge (rather than
# overwrite) is what keeps paperclip's own instructions* keys and anything an
# operator set on the board — only the keys <desired-config-fn> names are
# asserted.
#
# Reconciling rather than create-only matters: without it a change to the
# image only reaches agents created after that point, so the long-lived stack
# silently keeps the config it was born with and nothing surfaces the gap.
#
# Returns 1 when creation fails — and every call site must swallow that with
# `|| true`. This script runs under `set -e` as a one-shot that BOTH hermes and
# frontdoor wait on with `service_completed_successfully`, so letting one
# agent's failure propagate would abort the bootstrap: no further agents, and
# the whole stack stuck waiting on a dependency that will never complete. A
# per-agent failure must stay a loud line on stderr, not a stack outage.
#
# Scope of that `|| true`, stated precisely: POSIX suspends `set -e` for the
# entire dynamic extent of a function invoked as part of an AND-OR list, not
# just for the explicit `return 1` above. So every command that runs inside
# reconcile_agent for THIS call — the api_get lookups, the jq comparisons,
# the api_post_raw/api_patch_raw calls — is non-fatal for this invocation,
# not only the return path. That is fine here: every step that can fail
# already checks its own result explicitly (the `[ -n "$_ra_id" ]` guards,
# the `jq -e` verification on the PATCH response) and prints a WARNING/failed
# line rather than depending on `set -e` to notice — so widening `|| true`'s
# reach to the whole function does not hide a failure this code relies on
# `set -e` to catch, because it never relied on that in the first place.
reconcile_agent() {
    _ra_name="$1"
    _ra_type="$2"
    _ra_fn="$3"

    _ra_id="$(api_get "/companies/$company_id/agents" | \
        jq -r --arg n "$_ra_name" '.[]? | select(.name == $n) | .id' 2>/dev/null | head -1)"

    if [ -z "$_ra_id" ]; then
        _ra_id="$(printf '{}' | "$_ra_fn" \
            | jq -c --arg n "$_ra_name" --arg t "$_ra_type" \
                  '{name:$n, adapterType:$t, adapterConfig:.}' \
            | api_post_raw "/companies/$company_id/agents" | jq -r '.id // empty')"
        if [ -n "$_ra_id" ]; then
            echo "[pc-bootstrap] created agent: $_ra_name ($_ra_id)"
        else
            echo "[pc-bootstrap] $_ra_name creation failed" >&2
            return 1
        fi
        return 0
    fi

    _ra_cfg="$(api_get "/companies/$company_id/agents" \
        | jq -c --arg n "$_ra_name" '.[]? | select(.name == $n) | .adapterConfig // {}' | head -1)"
    _ra_want="$(printf '%s' "$_ra_cfg" | "$_ra_fn")"
    if [ "$(printf '%s' "$_ra_cfg" | jq -cS .)" = "$(printf '%s' "$_ra_want" | jq -cS .)" ]; then
        echo "[pc-bootstrap] agent exists: $_ra_name (config current)"
        return 0
    fi

    # Verified on the response, not on curl's exit: api_patch_raw ends in
    # `|| true`, so an `&&` here would report success for every failure —
    # the bug that left two skills stale on the board for several commits
    # while bootstrap printed "skill updated" every boot.
    if jq -nc --argjson c "$_ra_want" '{adapterConfig:$c}' \
         | api_patch_raw "/agents/$_ra_id" | jq -e '.id? // empty' >/dev/null 2>&1; then
        echo "[pc-bootstrap] agent $_ra_name: adapterConfig reconciled"
    else
        echo "[pc-bootstrap] WARNING could not reconcile $_ra_name adapterConfig" >&2
    fi
}

# ── 6. Prototyper agent (omp; scoped skills) ──
# HOME is deliberately NOT overridden: omp reads its model config from
# $HOME/.omp, so pointing HOME at the Claude credential home would break it.
# Skills are per-agent — the executor agent declares no paperclipSkillSync and
# therefore sees none of this.
#
# Everything the Prototyper needs lives in the desired config below, so a
# fresh `up` produces the same agent a hand-tuned board would. Fields NOT
# named here are paperclip's own defaults and need no assertion: heartbeat
# `{enabled:false, maxConcurrentRuns:20}`, permissions
# `{canCreateAgents:false, canCreateSkills:true}`, the managed AGENTS.md
# instructions bundle (paperclip writes instructions* on first run), the
# company membership and the `tasks:assign` grant (both minted at create).
PROTOTYPER_SKILLS='["prototype","prototype-workspace","devenv","podenv","container-tools"]'
PROTOTYPER_DEVENV_OWNER="${PAPERCLIP_PROTOTYPER_DEVENV_OWNER:-prototyper}"

# DEVENV_OWNER is the friendly label devenv stamps on leases. It is written
# in the canonical `{type:"plain"}` binding form because the API rewrites bare
# strings into it anyway (secrets.ts `canonicalizeBinding`) — writing the same
# shape the server persists keeps the diff stable instead of patching
# every boot. Note it does not currently reach the agent process: every local
# adapter's env loop does `if (typeof value !== "string") continue`, and the
# API can no longer persist a string. So devenv falls back to
# `agent:$PAPERCLIP_AGENT_ID`; this key is intent + board-visible
# documentation until upstream reads plain bindings.
proto_desired_config() { # live adapterConfig on stdin → desired on stdout
    jq -c --argjson skills "$PROTOTYPER_SKILLS" --arg owner "$PROTOTYPER_DEVENV_OWNER" '
          .engine = "acp"
        | .agentCommand = "omp acp --yolo"
        | .paperclipSkillSync = ((.paperclipSkillSync // {}) | .desiredSkills = $skills)
        | .env = ((.env // {}) | .DEVENV_OWNER = {type: "plain", value: $owner})
    '
}

reconcile_agent "$PROTOTYPER_NAME" claude_local proto_desired_config || true

_prototyper_id="$(api_get "/companies/$company_id/agents" | \
    jq -r --arg n "$PROTOTYPER_NAME" '.[]? | select(.name == $n) | .id' 2>/dev/null | head -1)"
if [ -z "$_prototyper_id" ]; then
    echo "[pc-bootstrap] WARNING Prototyper instruction reconcile skipped: exact-name lookup failed" >&2
else
    reconcile_agent_instructions "$_prototyper_id" "$PROTOTYPER_PROMPT" || true
fi

# ── 7. Scientist agent (remote hermes profile) ──
# Unlike the two local agents above, this one runs somewhere else: the hermes
# gateway container serves it as the `agt-scientist` profile, and paperclip
# reaches it over the built-in hermes_gateway adapter. normalizeBaseUrl keeps
# the path (gateway/server/execute.ts:121-140), which is what makes the
# per-profile /p/<name> route usable as a base URL.
#
# sessionKeyStrategy "agent" keys the session on companyId+agentId alone, so
# it is stable across issues and runs — one continuous session, which for a
# research agent is the point rather than a hazard.
SCIENTIST_BASE="${HERMES_SCIENTIST_BASE_URL:-http://hermes:8642/p/agt-scientist}"
SCIENTIST_KEY="${HERMES_SCIENTIST_API_KEY:-}"

# Wall-clock cap on one Scientist run. The adapter's own default is 600s
# (gateway/shared/constants.ts DEFAULT_TIMEOUT_SEC), and 600s is too short for
# this lane: the first real research task filed against the Scientist
# (pgvector HNSW benchmark, OPC-11) was killed at 601.7s — mid `tool.started`,
# with `[hermes-gateway] stop requested for run …` as the only trace — after
# it had already loaded the dataset and taken its first measurements. It
# resumed on the next wake and finished, but only because sessionKeyStrategy
# is "agent"; the timed-out run is still a real cost (a `timed_out` row, a
# re-read of the whole context, and an issue that sits in in_progress until
# something wakes it again).
#
# This is a WALL-CLOCK cap, not an idle timeout — the agent was working
# continuously when it was cut. A single measurement sweep in this lane is
# minutes on its own (the 100k-row HNSW build alone was 87s), so 600s buys
# nothing but interrupted work.
#
# There is no outer cap to coordinate with: paperclip has no run-duration
# watchdog of its own (the only timeout that fired here came from the adapter,
# via `POST /v1/runs/<id>/stop`), so this is the single knob.
#
# Asserted rather than left to the board on purpose: the reconcile below
# overwrites the keys it names, so a value edited in the dashboard would be
# silently reverted on the next boot. Keeping it here means the number has a
# stated reason. Raising it further trades against a genuinely stuck run
# holding its slot for that much longer — 1800s is 3x the observed task, not
# an upper bound on patience.
SCIENTIST_TIMEOUT_SEC="${HERMES_SCIENTIST_TIMEOUT_SEC:-1800}"

# Validated before it reaches jq, because the failure would not look like a
# bad number: it is passed with --argjson (the adapter reads timeoutSec as a
# number, and a quoted "1800" is not one), so a non-numeric value makes jq
# exit non-zero with EMPTY stdout — sci_desired_config then emits no desired
# config at all, and the reconcile is comparing against nothing rather than
# reporting a typo. Fall back to the default instead, loudly.
case "$SCIENTIST_TIMEOUT_SEC" in
    '' | *[!0-9]* )
        echo "[pc-bootstrap] WARNING HERMES_SCIENTIST_TIMEOUT_SEC='$SCIENTIST_TIMEOUT_SEC' is not a positive integer — using 1800" >&2
        SCIENTIST_TIMEOUT_SEC=1800
        ;;
    0 )
        # 0 means "no timeout" to the adapter (timeoutSec > 0 ? ... : 0 in
        # gateway/server/execute.ts). Allowed, but say so — an unbounded run
        # has no way to end itself.
        echo "[pc-bootstrap] NOTE HERMES_SCIENTIST_TIMEOUT_SEC=0 — Scientist runs will have no wall-clock timeout" >&2
        ;;
esac

# apiKey is a schema SECRET field for hermes_gateway (its config-schema marks
# `meta.secret`, and secrets.ts FALLBACK_ADAPTER_SCHEMA_SECRET_FIELDS lists it
# even when the schema is unavailable). A plain string sent for such a field is
# NOT stored as sent: normalizeSchemaSecretFieldForPersistence mints a brand-new
# managed secret named `hermes_gateway.apikey.<random-uuid>` and persists a
# `{type:"secret_ref"}` binding pointing at it. So what we send can never equal
# what we read back — a naive assert-and-compare PATCHes on EVERY boot and mints
# another orphaned secret every time (seven accumulated before this was caught),
# and `agent exists: … (config current)` can never print. Same canonicalization
# trap as DEVENV_OWNER above, one layer deeper.
#
# There is no read path for a company secret's value (routes/secrets.ts exposes
# create/rotate/patch/usage, never the plaintext), so "did the key change?"
# cannot be answered by comparing values. Carry a one-way digest of the desired
# key in the config instead: when the live record already holds a secret_ref AND
# the stored digest matches this key, leave apiKey untouched so desired == live
# and nothing is patched. When the digest differs (key rotated in .env), or
# apiKey is absent, or it is still a plain string, assert the key — one PATCH
# re-mints it and stamps the new digest, and the next boot is quiet again.
# The digest is a truncated sha256, not the credential.
#
# This runs at top level, outside reconcile_agent's `|| true` isolation (it
# has to: the empty-key guard a few lines down also needs it). Verified safe
# under `set -e` regardless: this script's shell is dash (no `pipefail`
# anywhere, and POSIX sh has no such option at all), so a pipeline's exit
# status is that of its LAST command only. A missing sha256sum would make
# that stage exit 127, but `cut` still runs on the now-empty stream and exits
# 0 — confirmed with `sh -c 'set -e; printf x | nonexistent_cmd | cut -c1-16;
# echo ok'`, which prints `ok` rather than aborting. The assignment succeeds
# with an empty fingerprint, sci_desired_config's `$fp` comparison then never
# matches a real digest, and the worst case is one extra (harmless) PATCH per
# boot — not the stack-outage shape Finding 2's `|| true` exists to prevent.
# /usr/bin/sha256sum is present in this image today, so this is a fallback
# behaviour, not a live defect.
SCIENTIST_KEY_FP="$(printf '%s' "$SCIENTIST_KEY" | sha256sum | cut -c1-16)"

# Fingerprint-plus-type is not enough to call the key "current": it never
# checks that the secret_ref actually resolves. A secret row can disappear
# out from under a config that still points at it — `DELETE /api/secrets/:id`
# has no reference guard, and nine unreferenced `hermes_gateway.apikey.*`
# rows exist today precisely because deletion is unconstrained — or a
# rotation PATCH can land the new fingerprint while the secret write itself
# fails. Either way the live record looks superficially fine (right
# fingerprint, `apiKey` is an object) while pointing at nothing, every
# Scientist run then fails on an unresolvable reference, and bootstrap prints
# "config current" forever — the exact silent-divergence class this whole
# reconcile exists to close. So membership in the live secret set is part of
# "current", not just shape and fingerprint. Fetched once per boot (cheap,
# read-only); `[]` on any fetch hiccup makes every secret_ref look dangling,
# which just re-asserts the key — the safe direction to fail in.
#
# The trailing `|| true` is load-bearing under `set -e`, same reasoning as
# Finding 3 above: without it, a jq failure on unexpected/empty input (e.g.
# api_get's own curl failing) would make this top-level assignment abort the
# whole bootstrap — the pipeline's exit status is jq's (its last command),
# and this line runs outside reconcile_agent's isolation.
SCIENTIST_SECRET_IDS="$(api_get "/companies/$company_id/secrets" | jq -c '[.[]?.id]' 2>/dev/null || true)"
case "$SCIENTIST_SECRET_IDS" in '['*']') ;; *) SCIENTIST_SECRET_IDS='[]' ;; esac

sci_desired_config() { # live adapterConfig on stdin → desired on stdout
    # dangerouslyAllowInsecureRemoteHttp: paperclip's hermes_gateway adapter
    # (transport-security.ts isRemotePlainHttp) refuses plain http to any
    # hostname it does not consider loopback — "hermes" is a compose DNS
    # name, not localhost/127.0.0.1, so without this the run fails closed
    # with errorCode hermes_gateway_plain_http_remote_denied before it ever
    # sends a request. There is no TLS anywhere on the compose-internal
    # network (every other inter-service hop in this stack is plain http on
    # a private docker network too), so this is the same trust boundary the
    # rest of the stack already relies on, not a new one.
    # `.apiKey.secretId` is captured as `$sid` BEFORE piping into `$ids`: a
    # filter passed as an argument to a builtin (`index(EXPR)`) is evaluated
    # against whatever `.` is at that point in the pipeline, which after
    # `$ids | ...` is `$ids` itself, not the top-level config — writing
    # `$ids | index(.apiKey.secretId)` fails with "Cannot index array with
    # string ("apiKey")" because `.` is already the id array by then.
    jq -c --arg base "$SCIENTIST_BASE" --arg key "$SCIENTIST_KEY" --arg fp "$SCIENTIST_KEY_FP" \
          --argjson timeout "$SCIENTIST_TIMEOUT_SEC" \
          --argjson ids "$SCIENTIST_SECRET_IDS" '
          (.apiKey.secretId // null) as $sid
        | (((.apiKeyFingerprint // "") == $fp)
            and ((.apiKey | type) == "object")
            and ($sid != null)
            and (($ids | index($sid)) != null)
          ) as $key_current
        | .apiBaseUrl = $base
        | .sessionKeyStrategy = "agent"
        | .timeoutSec = $timeout
        | .dangerouslyAllowInsecureRemoteHttp = true
        | .apiKeyFingerprint = $fp
        | if $key_current then . else .apiKey = $key end
    '
}

# Unreachable via compose: docker-compose.yml passes
# `${HERMES_SCIENTIST_API_KEY:?set in .env}`, and `:?` already aborts `up` on an
# unset OR empty value. Kept for direct invocation of this script (a hand-run,
# or `docker compose exec paperclip opc-paperclip-bootstrap.sh`), where nothing
# upstream of here checks — an empty key would otherwise create an agent that
# fails every run with hermes_gateway_api_key_missing.
if [ -z "$SCIENTIST_KEY" ]; then
    echo "[pc-bootstrap] WARNING HERMES_SCIENTIST_API_KEY empty — skipping Scientist agent" >&2
else
    reconcile_agent "$SCIENTIST_NAME" hermes_gateway sci_desired_config || true
fi

echo "[pc-bootstrap] done. admin=$ADMIN_EMAIL company=$company_id agent=$AGENT_NAME"
