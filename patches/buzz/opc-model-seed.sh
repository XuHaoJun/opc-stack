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

# JSON strings are also YAML strings. Encode data, never interpolate it as
# YAML syntax (e.g. Workers AI ids start with the reserved character @).
opc_yaml_quote() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

# Read scalar fields in the model/modelRoles block, including our escaped
# JSON strings and single-quoted values written by the Hermes dashboard.
opc_yaml_field() { # <file> <key>
    [ -f "$1" ] || return 0
    python3 - "$1" "$2" <<'PY'
import re
import sys

escapes = {
    "0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n",
    "v": "\v", "f": "\f", "r": "\r", "e": "\x1b", " ": " ", '"': '"',
    "/": "/", "\\": "\\", "N": "\x85", "_": "\xa0", "L": "\u2028", "P": "\u2029",
}


def unescape(match):
    token = match[1]
    return chr(int(token[1:], 16)) if token[0] in "xuU" else escapes[token]


inside = False
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        if re.match(r"^(model|modelRoles):\s*(?:#.*)?$", line):
            inside = True
            continue
        if inside and line.strip() and not line[0].isspace():
            inside = False
        if inside and line.startswith("  " + sys.argv[2] + ": "):
            value = line.split(": ", 1)[1].strip()
            quoted = re.fullmatch(r'"((?:[^"\\]|\\.)*)"(?:[ \t]+#.*)?', value)
            if quoted:
                value = re.sub(r"\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|.)",
                               unescape, quoted[1])
            elif value.startswith("'") and value.endswith("'"):
                value = value[1:-1].replace("''", "'")
            print(value)
            break
PY
}

# Rewrite that same line in place, leaving every other byte alone.
opc_yaml_set() ( # <file> <key> <value>; caller holds the model lock
    _tmp="$(mktemp "$1.opc-tmp.XXXXXX")"
    trap 'rm -f "$_tmp"' 0
    OPC_YAML_VALUE="$(opc_yaml_quote "$3")" awk -v k="$2" '
        BEGIN { v = ENVIRON["OPC_YAML_VALUE"] }
        /^(model|modelRoles):[[:space:]]*(#.*)?$/ { ins = 1; print; next }
        ins && /^[^[:space:]]/ { ins = 0 }
        ins && index($0, "  " k ": ") == 1 { print "  " k ": " v; ins = 0; next }
        { print }
    ' "$1" >"$_tmp"
    chmod --reference="$1" "$_tmp"
    mv "$_tmp" "$1"
)

opc_seed_ledger_get() { # <ledger> <key>
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | head -n 1
}

# Caller holds .opc-model-seed.lock across the config/ledger transaction.
opc_seed_ledger_set() ( # <ledger> <key> <value>
    [ -f "$1" ] || : >"$1"
    _tmp="$(mktemp "$1.opc-tmp.XXXXXX")"
    trap 'rm -f "$_tmp"' 0
    OPC_LEDGER_VALUE="$3" awk -v k="$2" '
        BEGIN { v = ENVIRON["OPC_LEDGER_VALUE"] }
        index($0, k "=") == 1 { print k "=" v; found = 1; next }
        { print }
        END { if (!found) print k "=" v }
    ' "$1" >"$_tmp"
    chmod --reference="$1" "$_tmp"
    mv "$_tmp" "$1"
)

# Follow the desired value unless someone else owns the field.
#   opc_model_follow <config> <key> <desired> <bootstrap-list>
opc_model_follow() (
    [ -f "$1" ] || return 0
    _led="$(dirname "$1")/.opc-model-seed"
    exec 8>"$_led.lock"
    flock 8
    _cur="$(opc_yaml_field "$1" "$2")"
    [ -n "$_cur" ] || return 0
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
)

# Seed omp's provider + default role for the endpoint in the environment.
# Reads OMP_CONFIG_DIR (default $HOME/.omp), OPENAI_BASE_URL, OPENAI_MODEL and
# the optional OMP_MODEL_CONTEXT_WINDOW / OMP_MODEL_MAX_TOKENS metadata knobs.
opc_omp_seed() (
    _dir="${OMP_CONFIG_DIR:-${HOME:-/root}/.omp}/agent"
    mkdir -p "$_dir"
    exec 9>"$_dir/.opc-omp-seed.lock"
    flock 9
    _models="$_dir/models.yml"
    _cfg="$_dir/config.yml"
    _model="${OPENAI_MODEL:-deepseek-v4.1-flash}"
    _base="${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}"
    _quoted_model="$(opc_yaml_quote "$_model")"
    _want="providers:
  opc:
    baseUrl: $(opc_yaml_quote "$_base")
    apiKey: \"OPENAI_API_KEY\"
    api: openai-completions
    models:
      - id: ${_quoted_model}
        name: ${_quoted_model}"
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
        # omp prefers .yml over .yaml and migrates .json only if neither
        # YAML file exists. Creating ours would silently hide operator data.
        if [ -f "$_dir/models.yaml" ] || [ -f "$_dir/models.json" ]; then
            echo "[opc] existing models.yaml/models.json is operator-owned — not seeding provider or role" >&2
            return 0
        fi
        _ours=1
    elif [ -f "$_stamp" ] && [ "$(sha256sum "$_models" | cut -d' ' -f1)" = "$(cat "$_stamp")" ]; then
        _ours=1
    fi
    if [ "$_ours" = 1 ]; then
        _tmp="$(mktemp "$_models.opc-tmp.XXXXXX")"
        trap 'rm -f "$_tmp"' 0
        printf '%s\n' "$_want" >"$_tmp"
        chmod 644 "$_tmp"
        mv "$_tmp" "$_models"
        sha256sum "$_models" | cut -d' ' -f1 >"$_stamp"
    else
        echo "[opc] WARNING $_models was changed outside OPC — leaving it alone; provider 'opc' will not follow OPENAI_BASE_URL/OPENAI_MODEL (remove the file to hand it back)" >&2
        return 0
    fi

    if [ ! -f "$_cfg" ]; then
        if [ -f "$_dir/config.yaml" ]; then
            return 0
        fi
        _tmp="$(mktemp "$_cfg.opc-tmp.XXXXXX")"
        trap 'rm -f "$_tmp"' 0
        printf 'modelRoles:\n  default: %s\nstartup:\n  quiet: true\n' "$(opc_yaml_quote "opc/$_model")" >"$_tmp"
        chmod 644 "$_tmp"
        mv "$_tmp" "$_cfg"
    fi
    # Only point the role at `opc` while the provider file is ours: with a
    # hand-written models.yml there may be no `opc` provider, and a role naming
    # a provider that does not exist fails the first model call.
    if [ "$_ours" = 1 ]; then
        opc_model_follow "$_cfg" default "opc/${_model}" "$OPC_STACK_OMP_MODEL_DEFAULTS"
    fi
)
