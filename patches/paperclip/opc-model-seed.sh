#!/bin/sh
# OPC model seeding — the single definition of "what model does this stack run,
# and where does that answer live".
#
# The answer is the container environment (.env): OPENAI_BASE_URL,
# OPENAI_MODEL, OPENAI_API_KEY. Every consumer follows it:
#
#   * hermes config.yaml — frontdoor, gateway default profile, expert profiles
#     (`model: {provider: custom, base_url, default}`)
#   * omp models.yml     — one custom provider, `opc`, pointed at
#     OPENAI_BASE_URL; no built-in provider slug is involved
#   * omp config.yml     — `modelRoles.default: opc/$OPENAI_MODEL`
#
# Two properties make switching endpoint or model an .env edit plus
# `docker compose up -d`, instead of an image change plus a per-volume hand
# edit:
#
# 1. Nothing is enumerated. The model string is passed through verbatim, so it
#    is whatever the endpoint names the model — the exact same string hermes
#    sends. omp used to pin the built-in `opencode-go` provider
#    (`opencode-go/$OPENAI_MODEL`, credential `OPENCODE_API_KEY`), which tied
#    omp to opencode.ai: on any other OpenAI-compatible endpoint the seeded
#    model could not be reached at all, and the model id was mangled.
# 2. The files are operator-editable, and hermes rewrites its own config.yaml
#    when someone runs /model, so re-stamping them on every boot would revert
#    that choice forever. Instead each field we write is recorded in an
#    `opc-model-seed` ledger (and models.yml by content hash); a field is
#    rewritten only while it still holds the value we last wrote. Once
#    something else changes it, OPC stops touching it.
#
# OPC_STACK_*_DEFAULTS is the bootstrap exception, not the mechanism: a volume
# written before the ledger existed has no record, so a value that is one of
# the stack's historical defaults is adopted as ours once. These lists are
# frozen history — adding a new default to them is NOT how the stack is moved
# (.env is); they only exist so an old volume reaches the new value at all.

# Historical stack defaults (model ids, then endpoint URLs). Append the
# outgoing value here only when OPC's own default changes; never remove.
OPC_STACK_MODEL_DEFAULTS="deepseek-v4-pro deepseek-v4-flash deepseek-v4.1-flash deepseek/deepseek-v4.1-flash"
OPC_STACK_BASE_URL_DEFAULTS="https://opencode.ai/zen/go/v1 https://api.commandcode.ai/provider/v1"
# Same, for the omp role that older images seeded as `opencode-go/<model>`.
OPC_STACK_OMP_MODEL_DEFAULTS="opencode-go/deepseek-v4-pro opencode-go/deepseek-v4-flash opencode-go/deepseek-v4.1-flash"

# Read `  <key>: <value>` from config.yaml's `model:` / config.yml's
# `modelRoles:` block. Prints nothing when the section or key is absent.
# Surrounding quotes are stripped: a dashboard save (hermes dumps YAML) can
# quote the value, and `"opc/x"` must still read as the value we wrote, or the
# field silently stops following .env after the first dashboard save.
opc_yaml_field() { # <file> <key>
    [ -f "$1" ] || return 0
    awk -v k="$2" -v sq="'" '
        /^(model|modelRoles):[[:space:]]*$/ { ins = 1; next }
        ins && /^[^[:space:]]/ { ins = 0 }
        ins && index($0, "  " k ": ") == 1 {
            sub("^  " k ": ", "")
            sub(/^"/, ""); sub(/"$/, "")
            sub("^" sq, ""); sub(sq "$", "")
            print; exit
        }
    ' "$1"
}

# Rewrite that same line in place, leaving every other byte alone.
opc_yaml_set() { # <file> <key> <value>
    _tmp="$1.opc-tmp"
    awk -v k="$2" -v v="$3" '
        /^(model|modelRoles):[[:space:]]*$/ { ins = 1; print; next }
        ins && /^[^[:space:]]/ { ins = 0 }
        ins && index($0, "  " k ": ") == 1 { print "  " k ": " v; ins = 0; next }
        { print }
    ' "$1" >"$_tmp" && mv "$_tmp" "$1"
}

opc_seed_ledger_get() { # <ledger> <key>
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | head -n 1
}

opc_seed_ledger_set() { # <ledger> <key> <value>
    [ -f "$1" ] || : >"$1"
    if grep -q "^$2=" "$1" 2>/dev/null; then
        _tmp="$1.opc-tmp"
        awk -v k="$2" -v v="$3" '
            index($0, k "=") == 1 { print k "=" v; next }
            { print }
        ' "$1" >"$_tmp" && mv "$_tmp" "$1"
    else
        printf '%s=%s\n' "$2" "$3" >>"$1"
    fi
}

# Follow the desired value unless someone else owns the field.
#   opc_model_follow <config> <key> <desired> <bootstrap-list>
opc_model_follow() {
    [ -f "$1" ] || return 0
    _cur="$(opc_yaml_field "$1" "$2")"
    [ -n "$_cur" ] || return 0
    _led="$(dirname "$1")/.opc-model-seed"
    _prev="$(opc_seed_ledger_get "$_led" "$2")"
    if [ "$_cur" != "$3" ]; then
        if [ -n "$_prev" ]; then
            # Only a value we wrote is ours to move.
            [ "$_cur" = "$_prev" ] || return 0
        else
            # Pre-ledger volume: adopt a known historical default, nothing else.
            case " $4 " in
                *" $_cur "*) ;;
                *) return 0 ;;
            esac
        fi
        opc_yaml_set "$1" "$2" "$3"
    fi
    opc_seed_ledger_set "$_led" "$2" "$3"
}

# Seed omp's provider + default role for the endpoint in the environment.
# Reads OMP_CONFIG_DIR (default $HOME/.omp), OPENAI_BASE_URL, OPENAI_MODEL and
# the optional OMP_MODEL_CONTEXT_WINDOW / OMP_MODEL_MAX_TOKENS metadata knobs.
opc_omp_seed() {
    _dir="${OMP_CONFIG_DIR:-${HOME:-/root}/.omp}/agent"
    mkdir -p "$_dir"
    _models="$_dir/models.yml"
    _cfg="$_dir/config.yml"
    _model="${OPENAI_MODEL:-deepseek-v4.1-flash}"
    _base="${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}"
    _want="providers:
  opc:
    baseUrl: ${_base}
    apiKey: OPENAI_API_KEY
    api: openai-completions
    models:
      - id: ${_model}
        name: ${_model}"
    if [ -n "${OMP_MODEL_CONTEXT_WINDOW:-}" ]; then
        _want="$_want
        contextWindow: ${OMP_MODEL_CONTEXT_WINDOW}"
    fi
    if [ -n "${OMP_MODEL_MAX_TOKENS:-}" ]; then
        _want="$_want
        maxTokens: ${OMP_MODEL_MAX_TOKENS}"
    fi

    # The provider entry is ours to maintain only while it is still what we
    # wrote: a stamp of the last content we generated is the provenance record
    # (models.yml has no field we could reconcile individually without
    # learning YAML merging, and it is a file omp never rewrites itself).
    _stamp="$_dir/.opc-models-sha"
    _ours=0
    if [ ! -f "$_models" ]; then
        _ours=1
    elif [ -f "$_stamp" ] && [ "$(sha256sum "$_models" | cut -d' ' -f1)" = "$(cat "$_stamp")" ]; then
        _ours=1
    fi
    if [ "$_ours" = 1 ]; then
        printf '%s\n' "$_want" >"$_models"
        chmod 644 "$_models"
        sha256sum "$_models" | cut -d' ' -f1 >"$_stamp"
    else
        echo "[opc] WARNING $_models was changed outside OPC — leaving it alone; provider 'opc' will not follow OPENAI_BASE_URL/OPENAI_MODEL (remove the file to hand it back)" >&2
    fi

    if [ ! -f "$_cfg" ]; then
        printf 'modelRoles:\n  default: opc/%s\nstartup:\n  quiet: true\n' "$_model" >"$_cfg"
    fi
    # Only point the role at `opc` while the provider file is ours: with a
    # hand-written models.yml there may be no `opc` provider, and a role naming
    # a provider that does not exist fails the first model call.
    if [ "$_ours" = 1 ]; then
        opc_model_follow "$_cfg" default "opc/${_model}" "$OPC_STACK_OMP_MODEL_DEFAULTS"
    fi
}
