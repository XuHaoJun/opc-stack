#!/bin/sh
# Hermes entrypoint: seed the /nix volume, seed an OPC config (kanban toolset
# + dispatcher OFF — Paperclip is the canonical work plane; model = OpenCode
# Go custom OpenAI-compatible endpoint), then hand off to the upstream s6
# entrypoint dispatcher.
set -eu

. /usr/local/bin/opc-nix-seed.sh
opc_nix_seed

# Mise toolchains: node@lts + rust@stable + omp on the *-mise volume.
. /usr/local/bin/opc-mise-seed.sh
opc_mise_seed

. /usr/local/bin/opc-gh-seed.sh
opc_gh_seed

# Bootstrap one-shots write /keys/paperclip-api.key (paperclip-bootstrap) and
# /keys/tencentdb-admin-user-id (tencentdb-bootstrap) after `docker compose
# down -v`. A container that boots before its one-shot finishes would run with
# empty PAPERCLIP_API_KEY — the paperclip skill then gets
# 403 "Board access required" on every call and looks like a dead integration.
# compose depends_on orders services; this bounded wait covers manual
# / --no-deps / recreated-container starts where the file may lag the process.
wait_for_keys() {
    missing=""
    for f in "$@"; do
        [ -s "$f" ] || missing="$missing $f"
    done
    [ -z "$missing" ] && return 0
    echo "[hermes] waiting for key file(s):$missing (bootstrap one-shot)…"
    n=0
    while [ "$n" -lt 90 ]; do
        n=$((n + 1))
        sleep 2
        missing=""
        for f in "$@"; do
            [ -s "$f" ] || missing="$missing $f"
        done
        [ -z "$missing" ] && { echo "[hermes] key files ready after $((n * 2))s"; return 0; }
    done
    echo "[hermes] WARNING: key files still missing after 180s:$missing — paperclip/memory integrations unavailable; a missing scientist.nsec additionally leaves the expert profile with no Buzz identity (buzz reports \"no buzz identity\" and quietly does not send)"
    return 1
}
wait_for_keys /keys/paperclip-api.key /keys/tencentdb-admin-user-id /keys/scientist.nsec

# Paperclip board API key written by the paperclip-bootstrap one-shot: the
# keys volume is the single source of truth (no .env variable anymore).
if [ -f /keys/paperclip-api.key ]; then
    export PAPERCLIP_API_KEY="$(cat /keys/paperclip-api.key)"
    echo "[hermes] PAPERCLIP_API_KEY loaded from keys volume"
fi
# TencentDB admin user_id written by the tencentdb-bootstrap one-shot: scopes
# memory writes (L0/L1) under the panel owner so the Memory Hub panel at 8125
# can render them (the panel queries with asset.owner_user_id).
if [ -f /keys/tencentdb-admin-user-id ]; then
    export MEMORY_TENCENTDB_USER_ID="$(cat /keys/tencentdb-admin-user-id)"
    echo "[hermes] MEMORY_TENCENTDB_USER_ID loaded from keys volume"
fi

HH="${HERMES_HOME:-/opt/data}"

# TencentDB Knowledge Plane (PRD v10.1): sync the memory_tencentdb Hermes
# MemoryProvider into $HERMES_HOME/plugins/ (user-plugin discovery path) on
# every boot — image updates propagate into existing volumes.
MP_SRC="/opt/hermes/memory_tencentdb"
MP_DST="$HH/plugins/memory_tencentdb"
if [ -d "$MP_SRC" ]; then
    mkdir -p "$HH/plugins"
    rm -rf "$MP_DST"
    cp -r "$MP_SRC" "$MP_DST"
    echo "[hermes] synced memory provider: memory_tencentdb"
fi

# paperclip-api skill (GitHub integration): sync from image on every boot.
SK_SRC="/opt/hermes/skills/paperclip-api"
SK_DST="$HH/skills/paperclip-api"
if [ -d "$SK_SRC" ]; then
    mkdir -p "$HH/skills"
    rm -rf "$SK_DST"
    cp -r "$SK_SRC" "$SK_DST"
    echo "[hermes] synced skill: paperclip-api"
fi


# Agent identity: sync SOUL.md from the image on every boot.
#
# This is where the "you are not the implementer" rule lives, and it has to be
# here rather than in config.yaml's agent.system_prompt: that key is resolved
# by `class HermesCLI` in cli.py, so it applies to `hermes chat` and NOT to
# `hermes acp` — the lane this front door actually runs. AIAgent builds SOUL.md
# into its own prompt (agent/system_prompt.py -> load_soul_md, scoped to the
# agent's own home), so SOUL.md holds in every lane.
#
# Overwritten every boot on purpose: the image is the source of truth, the same
# way skills are. config.yaml is NOT a safe place for a rule that must hold —
# hermes migrates that file and this volume arrived at _config_version 37 with
# its seeded system_prompt silently gone.
if [ -f /opt/hermes/SOUL.md ]; then
    mkdir -p "$HH"
    cp /opt/hermes/SOUL.md "$HH/SOUL.md"
    echo "[hermes] synced SOUL.md (agent identity + delegation rule)"
fi

if [ ! -f "$HH/config.yaml" ]; then
    mkdir -p "$HH"
    cat > "$HH/config.yaml" <<YAML
_config_version: 34
agent:
  disabled_toolsets:
    - kanban
kanban:
  dispatch_in_gateway: false
  review_dispatch: false
  auto_decompose: false
memory:
  provider: memory_tencentdb
model:
  provider: custom
  api_key: \${OPENAI_API_KEY}
  base_url: ${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}
  default: ${OPENAI_MODEL:-deepseek-v4-flash}
YAML
    echo "[hermes] seeded $HH/config.yaml (kanban disabled; memory=tencentdb; model=${OPENAI_MODEL:-deepseek-v4-flash})"
fi

# Refresh seeded model lines on existing volumes that still carry the legacy
# hardcoded default (config.yaml is dashboard-editable afterwards; only the
# exact legacy values are rewritten, not user edits).
if [ -f "$HH/config.yaml" ]; then
    sed -i "s|^  default: deepseek-v4-pro$|  default: ${OPENAI_MODEL:-deepseek-v4-flash}|; s|^  base_url: https://opencode\\.ai/zen/go/v1$|  base_url: ${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}|" "$HH/config.yaml"
    # Existing editable configs may predate the explicit custom-provider key
    # route. Insert only when the model block has no api_key; operator-set
    # credentials are left untouched.
    python3 - "$HH/config.yaml" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    lines = handle.readlines()
start = next((i for i, line in enumerate(lines) if re.match(r"^model:\s*$", line)), None)
if start is None:
    raise SystemExit(0)
end = next(
    (i for i in range(start + 1, len(lines)) if lines[i].strip() and not lines[i].startswith((" ", "\t"))),
    len(lines),
)
block = lines[start:end]
if any(re.match(r"^  api_key\s*:", line) for line in block):
    raise SystemExit(0)
if not any(re.match(r"^  provider:\s*custom\s*$", line.rstrip("\n")) for line in block):
    raise SystemExit(0)
provider = next(i for i in range(start + 1, end) if re.match(r"^  provider:\s*custom\s*$", lines[i].rstrip("\n")))
lines.insert(provider + 1, "  api_key: ${OPENAI_API_KEY}\n")
with open(path, "w", encoding="utf-8") as handle:
    handle.writelines(lines)
print("[hermes] added model.api_key env reference to existing config")
PYEOF
    # Pre-s12 configs (no _config_version) trip hermes's "predates version
    # 12" migration refusal on every boot; stamp the current version once.
    if ! grep -q "^_config_version:" "$HH/config.yaml"; then
        sed -i "1i _config_version: 34" "$HH/config.yaml"
        echo "[hermes] stamped _config_version: 34 onto existing $HH/config.yaml"
    fi
fi


# Key routing: for provider "custom", Hermes reads OPENAI_API_KEY +
# OPENAI_BASE_URL from the environment (or $HERMES_HOME/.env).
: "${OPENAI_API_KEY:=}"
: "${OPENAI_BASE_URL:=https://opencode.ai/zen/go/v1}"
export OPENAI_API_KEY OPENAI_BASE_URL

# ── Expert agent profiles ──────────────────────────────────────────────
# Each expert is a named hermes profile under $HERMES_HOME/profiles/, served
# by this one gateway process (GATEWAY_MULTIPLEX_PROFILES=1). The directory
# lives on the hermes-profiles volume, which the dashboard also mounts — that
# is what puts the expert in the dashboard's global profile switcher
# (list_profiles() enumerates $HERMES_HOME/profiles).
#
# What opc_seed_expert_profile actually does today: create the profile's
# directory tree; seed config.yaml and .env when absent (both are
# dashboard-editable afterwards); keep API_SERVER_KEY in .env in sync with the
# operator's .env on every boot; converge .env on mode 600 whichever branch
# ran; and re-copy the memory plugin and the paperclip-api skill from the image
# (those two are image-owned, same as for the default profile). It does NOT
# write SOUL.md — the expert's identity lands here in a later task, and the
# SOUL.md already sitting in the profile is hermes's own default, written by
# the runtime.

# Mirror hermes's own acceptance rule for a per-profile gateway key.
# api_server.py::_expected_api_key() resolves a named profile's key through
# auth.py::has_usable_secret(key, min_length=16): anything shorter than 16
# characters after stripping, or one of upstream's placeholder strings,
# resolves to "" and then EVERY request to that profile 401s with nothing but a
# logger.warning buried in the gateway log. compose's `${VAR:?}` only catches
# empty, so a 6-char key or `your-api-key-here` sails through it — refuse the
# same values upstream refuses, loudly, at the point they are written.
opc_key_is_usable() { # <value>
    _v="$(printf '%s' "${1-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ "${#_v}" -ge 16 ] || return 1
    case "$(printf '%s' "$_v" | tr '[:upper:]' '[:lower:]')" in
        '*'|'**'|'***'|changeme|your_api_key|your_api_key_here|your-api-key|placeholder|example|dummy|null|none)
            return 1 ;;
    esac
    return 0
}

# Read one value out of a .env the way hermes parses it (config.py load_env +
# _parse_env_value, and agent/secret_scope.py::_strip_inline_comment for the
# comment handling): comments skipped, an `export ` prefix stripped, last
# assignment wins, an inline `# ...` comment stripped, surrounding quotes
# removed. Comparing raw file text instead would treat a dashboard-written
# `API_SERVER_KEY="…"` as different from the identical unquoted value and
# rewrite + log "refreshed" on every single boot; not stripping the inline
# comment the way upstream does causes the same spurious one-time rewrite for
# `KEY=abc # note` (self-healing on the next boot, but the log then lies
# about why it fired).
#
# Inline-comment rule mirrors _strip_inline_comment exactly: for a value
# starting with a quote, scan for the matching close quote (backslash-escape
# aware for double quotes only, since the writer emits \"/\\ escapes); if
# what follows the close quote, after leading whitespace, starts with `#`,
# keep only through the close quote — otherwise leave the value untouched
# (lenient, not a parse error). For an unquoted value, truncate at the first
# `#` that is preceded by whitespace, so `foo#bar` is kept whole but
# `foo # bar` becomes `foo`, and a value that itself starts with `#` is kept.
opc_env_value() { # <env-file> <name>
    [ -f "$1" ] || return 0
    awk -v want="$2" '
        BEGIN { sq = sprintf("%c", 39); dq = sprintf("%c", 34) }
        {
            line = $0
            sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line)
            if (line ~ /^#/ || index(line, "=") == 0) next
            sub(/^export[ \t]+/, "", line)
            k = substr(line, 1, index(line, "=") - 1)
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k != want) next
            v = substr(line, index(line, "=") + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            n = length(v)
            q = substr(v, 1, 1)
            if (n >= 1 && (q == dq || q == sq)) {
                i = 2; closed = 0; closeidx = 0
                while (i <= n) {
                    ch = substr(v, i, 1)
                    if (q == dq && ch == "\\") { i += 2 }
                    else if (ch == q) { closed = 1; closeidx = i; break }
                    else { i++ }
                }
                if (closed) {
                    rest = substr(v, closeidx + 1)
                    gsub(/^[ \t]+/, "", rest)
                    if (substr(rest, 1, 1) == "#") v = substr(v, 1, closeidx)
                    # else: non-comment trailing junk — leave v untouched
                }
                # else: unterminated quote — leave v untouched
            } else if (match(v, /[ \t]+#/) > 0) {
                v = substr(v, 1, RSTART - 1)
            }
            n = length(v)
            if (n >= 2 && ((substr(v, 1, 1) == dq && substr(v, n, 1) == dq) || \
                           (substr(v, 1, 1) == sq && substr(v, n, 1) == sq)))
                v = substr(v, 2, n - 2)
            out = v; found = 1
        }
        END { if (found) print out }
    ' "$1" 2>/dev/null
}

# The agent replies/posts by running the buzz CLI, but hermes scrubs
# BUZZ_PRIVATE_KEY from tool subprocess env (GHSA-rhgp-j443-p4rf: provider
# credentials never reach terminal children), so the CLI cannot authenticate.
# Wrap it to read the key from the profile home instead.
#
# $HERMES_HOME is what makes this per-profile under a single multiplexed
# process: terminal children get the context-local profile home bridged into
# their env by tools/environments/local.py `_inject_context_hermes_home`, so
# each expert's CLI picks up its OWN nsec.
#
# The wrapper resolves an identity ONLY when $HERMES_HOME names a directory
# DIRECTLY under the profiles root — i.e. an expert profile. Anything else
# (unset, the container's own home, the profiles root itself, a path nested
# deeper) resolves to no identity at all, and buzz then reports "no buzz
# identity" instead of signing as somebody.
#
# This is a structural rule, not a convenience. This image runs in TWO
# containers. In `hermes`, $HERMES_HOME is /opt/data on the hermes-data
# volume, whose root holds no .agent.nsec. In `hermes-dashboard` the SAME
# image and the SAME entrypoint run with /opt/data bound to frontdoor-hermes
# — and the frontdoor entrypoint copies the CHIEF OF STAFF's key to
# /opt/data/.agent.nsec there. A wrapper that falls back to
# "$HERMES_HOME/.agent.nsec" therefore signs every unscoped buzz invocation
# in that container as the chief of staff, which is precisely the identity
# leak this expert-agent work exists to prevent (/keys/agent.nsec is never
# shared with an expert). Keying off the profiles root makes the leak
# unreachable rather than merely unlikely.
#
# The frontdoor image keeps its own, different wrapper
# (patches/buzz/frontdoor-entrypoint.sh): there the chief of staff's key at
# $HERMES_HOME/.agent.nsec IS the correct identity.
if [ -x /usr/local/bin/buzz.bin ]; then
    cat > /usr/local/bin/buzz <<EOF
#!/bin/sh
# Expert identity, resolved only for a named profile under the profiles root.
_root="$HH/profiles"
_hh="\${HERMES_HOME:-}"
_nsec=""
case "\$_hh" in
    "\$_root"/*)
        _rest="\${_hh#"\$_root"/}"
        _rest="\${_rest%/}"
        case "\$_rest" in
            ''|.|..|*/*) ;;   # profiles root, dot paths, or nested deeper
            *) _nsec="\$_root/\$_rest/.agent.nsec" ;;
        esac
        ;;
esac
if [ -n "\$_nsec" ] && [ -r "\$_nsec" ]; then
    export BUZZ_PRIVATE_KEY="\${BUZZ_PRIVATE_KEY:-\$(cat "\$_nsec")}"
fi
export BUZZ_RELAY_URL="\${BUZZ_RELAY_URL:-${BUZZ_RELAY_URL:-ws://localhost:3000}}"
exec /usr/local/bin/buzz.bin "\$@"
EOF
    chmod +x /usr/local/bin/buzz
    echo "[hermes] buzz wrapper installed (identity only for $HH/profiles/<expert>)"
fi

opc_seed_expert_profile() { # <profile-name> <api-key-value>
    _p="$1"
    _key="$2"
    _ph="$HH/profiles/$_p"
    # The expert's key basename is DERIVED from the profile name below
    # (agt-<expert> -> /keys/<expert>.nsec). Exactly one name must never be
    # derivable that way: agt-agent resolves to /keys/agent.nsec — the chief
    # of staff's key — and would mirror it into an expert profile, handing an
    # expert the one identity it must never have. Refuse the name outright
    # rather than relying on nobody ever choosing it.
    _expert="${_p#agt-}"
    if [ "$_expert" = "agent" ]; then
        echo "[hermes] FATAL: profile name '$_p' is reserved — it would mirror /keys/agent.nsec (the chief of staff's identity) into an expert profile" >&2
        exit 1
    fi

    mkdir -p "$_ph/memories" "$_ph/sessions" "$_ph/skills" "$_ph/logs" \
             "$_ph/plans" "$_ph/workspace" "$_ph/cron" "$_ph/home" "$_ph/plugins"

    if opc_key_is_usable "$_key"; then
        _key_ok=1
    else
        _key_ok=0
        if [ -z "$_key" ]; then
            echo "[hermes] WARNING profile $_p has no API key — the gateway will 401 every request for it" >&2
        else
            echo "[hermes] WARNING profile $_p: API key rejected by hermes's own rule (needs >=16 chars after stripping and must not be a placeholder such as changeme / your-api-key / placeholder) — NOT writing it; the gateway will 401 every request for it" >&2
        fi
    fi

    # Per-profile secrets. Under multiplex the secret scope is authoritative
    # and does NOT fall back to os.environ (agent/secret_scope.py:137-152),
    # precisely so one profile cannot read another's credentials — so the
    # provider key has to be repeated here, it is not inherited.
    if [ ! -f "$_ph/.env" ]; then
        : > "$_ph/.env"
        chmod 600 "$_ph/.env"
        [ "$_key_ok" = 1 ] && printf 'API_SERVER_KEY=%s\n' "$_key" >> "$_ph/.env"
        printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY:-}" >> "$_ph/.env"
        printf 'OPENAI_BASE_URL=%s\n' "${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}" >> "$_ph/.env"
        echo "[hermes] seeded $_ph/.env"
    elif [ "$_key_ok" = 1 ] && [ "$(opc_env_value "$_ph/.env" API_SERVER_KEY)" != "$_key" ]; then
        # The API key is operator-rotatable via .env; keep it in sync without
        # touching anything else the dashboard may have written.
        #
        # Rewrite through a temp file rather than `sed -i /d` + `>>`: GNU sed
        # preserves a missing final newline, so appending to a file another
        # writer left unterminated — precisely the dashboard case this branch
        # exists for — lands the key on the end of the previous line
        # (`OPENAI_BASE_URL=…API_SERVER_KEY=xxx`), corrupting the provider URL
        # and the key at once, with a 401 as the only symptom. awk's print
        # always terminates the line, so this normalises the file instead.
        #
        # Pre-create the temp file at 600 before anything is written into it:
        # the shell's `>` redirection below truncates an existing file rather
        # than recreating it, so an existing 600 mode survives untouched — a
        # plain `awk ... > "$_tmp"` on a not-yet-existing path would instead
        # create it at the process umask (typically 644), leaving the API key
        # briefly world-readable between the write and the `mv` below.
        _tmp="$_ph/.env.opc-tmp.$$"
        : > "$_tmp"
        chmod 600 "$_tmp"
        if OPC_NEW_KEY="$_key" awk '
                BEGIN { k = ENVIRON["OPC_NEW_KEY"] }
                !/^[ \t]*(export[ \t]+)?API_SERVER_KEY[ \t]*=/ { print }
                END { print "API_SERVER_KEY=" k }
            ' "$_ph/.env" > "$_tmp"; then
            mv "$_tmp" "$_ph/.env"
            echo "[hermes] refreshed API_SERVER_KEY in $_ph/.env"
        else
            rm -f "$_tmp"
            echo "[hermes] WARNING could not refresh API_SERVER_KEY in $_ph/.env" >&2
        fi
    fi
    # Converge on 600 on every boot, not just on the create path: an .env that
    # already existed with a looser mode was never tightened, and neither was
    # the one the refresh branch just wrote through a fresh temp file.
    chmod 600 "$_ph/.env"

    if [ ! -f "$_ph/config.yaml" ]; then
        cat > "$_ph/config.yaml" <<YAML
_config_version: 34
agent:
  disabled_toolsets:
    - kanban
kanban:
  dispatch_in_gateway: false
  review_dispatch: false
  auto_decompose: false
memory:
  provider: memory_tencentdb
model:
  provider: custom
  api_key: \${OPENAI_API_KEY}
  base_url: ${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}
  default: ${OPENAI_MODEL:-deepseek-v4-flash}
YAML
        echo "[hermes] seeded $_ph/config.yaml"
    fi
    # model.api_key stays — this part IS established, both from source and
    # confirmed against the running gateway: dropping the line does NOT fall
    # back to the profile's secret scope, it breaks the profile outright.
    # runtime_provider.py:1325-1335 gates the OPENAI_API_KEY candidate on an
    # openai.com / openai.azure.com HOST, and this base_url is opencode.ai —
    # so a bare `custom` provider with no config api_key ends at the literal
    # "no-key-required" (:1360) and every completion 401s even with a
    # perfectly good key in the profile's .env. Same reason 1881e40 added it
    # to the default profile.
    #
    # What is NOT established: the mechanism behind ${...} resolution inside
    # a profile's config.yaml. Measured (2026-08-20, across a container
    # restart):
    #   * a var defined ONLY in profiles/<p>/.env resolved fine in that
    #     profile's own config.yaml ${VAR} reference;
    #   * default and agt-scientist both naming OPENAI_API_KEY but holding
    #     DIFFERENT values: after a restart, whichever profile served the
    #     first request decided the value BOTH routes then got — the other
    #     route started 401ing;
    #   * giving them distinct variable names instead behaved cleanly.
    # These three observations do not add up to "${VAR} resolves against the
    # profile's own .env" as a mechanism — reading the source points the
    # other way: config.py::_env_expand_match (~2591-2637) resolves ${VAR}
    # from os.environ ONLY and leaves an unresolved ref literal;
    # gateway/run.py:1963-1975 explicitly refuses to load a profile's .env
    # into os.environ under multiplex; and _profile_runtime_scope
    # (gateway/run.py:2067-2100) builds an isolated dict without ever
    # mutating os.environ. No path was found that would make per-profile-.env
    # resolution true — something else (a shared credential pool, or some
    # other global) is doing this, and which one is unknown. Do not "fix"
    # this comment from source reading alone.
    #
    # The operational rule holds regardless of the cause, so keep following
    # it: do not give two profiles different values under the same variable
    # name; an expert that needs its own provider key must use a distinct
    # variable name; verify credential behaviour here by measuring against
    # the running gateway, not by reading the source.

    # Memory provider: same image copy the default profile gets. The plugin
    # scopes writes by agent_identity (= the profile name) because
    # MEMORY_TENCENTDB_AGENT_ID is process-wide and must stay UNSET on this
    # container — that is why the profile is named agt-scientist and not
    # scientist (the panel parses chat_memory-{team}-{agent} with
    # lastIndexOf('-agt')).
    if [ -d "/opt/hermes/memory_tencentdb" ]; then
        rm -rf "$_ph/plugins/memory_tencentdb"
        cp -r /opt/hermes/memory_tencentdb "$_ph/plugins/memory_tencentdb"
    fi

    # paperclip-api skill: the expert files its own findings as backlog issues.
    if [ -d "/opt/hermes/skills/paperclip-api" ]; then
        rm -rf "$_ph/skills/paperclip-api"
        cp -r /opt/hermes/skills/paperclip-api "$_ph/skills/paperclip-api"
    fi

    # Runtime-uid key mirror. /keys is mounted read-only and its files are
    # 600 root, so the agent (uid 10000) and its terminal children cannot read
    # them there. The failure mode is silent and misdirected: an empty key
    # makes buzz report "no buzz identity" and quietly not send, which reads
    # as a relay problem rather than a missing credential.
    _nsec_src="/keys/$_expert.nsec"
    if [ -f "$_nsec_src" ]; then
        cp "$_nsec_src" "$_ph/.agent.nsec"
        chown "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$_ph/.agent.nsec" 2>/dev/null || true
        chmod 600 "$_ph/.agent.nsec"
        echo "[hermes] $_p: buzz identity mirrored from $_nsec_src"
    else
        echo "[hermes] WARNING $_p: no $_nsec_src — the expert cannot post to Buzz" >&2
    fi

    # Same problem, same fix, for the board key: the expert files its own
    # findings as backlog issues.
    if [ -f /keys/paperclip-api.key ]; then
        cp /keys/paperclip-api.key "$_ph/.paperclip-api.key"
        chown "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$_ph/.paperclip-api.key" 2>/dev/null || true
        chmod 600 "$_ph/.paperclip-api.key"
    fi

    echo "[hermes] expert profile ready: $_p"
}

opc_seed_expert_profile agt-scientist "${HERMES_SCIENTIST_API_KEY:-}"

# Single-owner home: everything under $HERMES_HOME must belong to the hermes
# runtime uid (10000) — the dashboard/gateway services run as that user, and
# the Buzz front-door agent (same shared frontdoor-hermes volume) runs as it
# too via its setpriv wrapper. A root-owned state.db/-wal is read-only for
# uid 10000 (preflight fails → "TUI session store unavailable" spam) and
# SQLite WAL cannot be shared across two unix users. Root entrypoint seeds
# (config.yaml, plugins, skills) are written before this line, so chown -R
# at boot keeps ownership deterministic even on pre-existing volumes.
chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$HH" 2>/dev/null || true

exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
