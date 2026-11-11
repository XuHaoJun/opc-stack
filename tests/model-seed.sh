#!/bin/sh
# Pin the model/base-url/omp-provider reconcile in patches/*/opc-model-seed.sh.
#
# Offline: the library is sourced in a temp dir and pointed at throwaway
# config files. Nothing touches the real checkout, images, containers or
# volumes. `scripts/prepare.sh` checks that the three copies of the library are
# byte-identical; this is the behavioural half.
#
# Every case here is a failure that actually happened or would silently
# survive a green stack:
#   * switching OPENAI_BASE_URL left the volume on the old model id, so the new
#     endpoint answered HTTP 400 `Model "<id>" is not supported on this
#     endpoint` while .env, the container env and the seed template all looked
#     right;
#   * omp was seeded as `opencode-go/$OPENAI_MODEL` and read OPENCODE_API_KEY,
#     so it never followed OPENAI_BASE_URL at all;
#   * and both files are edited by hand / by the hermes dashboard, so the fix
#     must not revert a human choice on the next boot.
set -eu
cd "$(dirname "$0")/.."

fx="$(mktemp -d)"
trap 'rm -rf "$fx"' EXIT

fail() { echo "FAIL  $1" >&2; exit 1; }
expect() { [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"; }

. patches/hermes/opc-model-seed.sh

hermes_home() { # <dir> <model> <base_url>
    mkdir -p "$1"
    cat >"$1/config.yaml" <<YAML
_config_version: 52
model:
  provider: custom
  api_key: \${OPENAI_API_KEY}
  base_url: $3
  default: $2
YAML
}

reconcile() { # <dir>
    opc_model_follow "$1/config.yaml" default "${OPENAI_MODEL:-deepseek-v4.1-flash}" "$OPC_STACK_MODEL_DEFAULTS"
    opc_model_follow "$1/config.yaml" base_url "${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}" "$OPC_STACK_BASE_URL_DEFAULTS"
}

field() { opc_yaml_field "$1/config.yaml" "$2"; }

# ── hermes: a pre-ledger volume follows a provider switch ──────────────────
H="$fx/h1"
hermes_home "$H" deepseek-v4.1-flash https://opencode.ai/zen/go/v1
OPENAI_MODEL='deepseek/deepseek-v4.1-flash'
OPENAI_BASE_URL='https://api.commandcode.ai/provider/v1'
reconcile "$H"
expect "$(field "$H" default)" "$OPENAI_MODEL" "stale seeded default must follow .env"
expect "$(field "$H" base_url)" "$OPENAI_BASE_URL" "seeded base_url must follow .env"

# The same switch again with a different model id — no list to maintain.
OPENAI_MODEL='Qwen/Qwen3.8-Max'
reconcile "$H"
expect "$(field "$H" default)" "$OPENAI_MODEL" "any model id must pass through verbatim"

# A dashboard save can quote the value (hermes dumps YAML). It is still the
# value we wrote, so the field must keep following .env.
sed -i 's|^  default: .*|  default: "Qwen/Qwen3.8-Max"|' "$H/config.yaml"
reconcile "$H"
OPENAI_MODEL='moonshotai/Kimi-K2.7-Code'
reconcile "$H"
expect "$(field "$H" default)" "$OPENAI_MODEL" "a quoted value we wrote must still follow .env"

# ── hermes: a model chosen by a human is not reverted ─────────────────────
H="$fx/h2"
hermes_home "$H" deepseek/deepseek-v4.1-flash "$OPENAI_BASE_URL"
opc_seed_ledger_set "$H/.opc-model-seed" default deepseek/deepseek-v4.1-flash
opc_yaml_set "$H/config.yaml" default claude-sonnet-5 # dashboard / /model
OPENAI_MODEL='deepseek/deepseek-v4.1-flash'
reconcile "$H"
expect "$(field "$H" default)" claude-sonnet-5 "an operator-chosen model must survive boot"

# …until .env names it again, at which point OPC owns the field again.
OPENAI_MODEL='claude-sonnet-5'
reconcile "$H"
OPENAI_MODEL='moonshotai/Kimi-K3'
reconcile "$H"
expect "$(field "$H" default)" moonshotai/Kimi-K3 "field returns to OPC control once .env matches it"

# ── hermes: a pre-ledger volume with an unknown model is left alone ───────
H="$fx/h3"
hermes_home "$H" gpt-6.1-sol https://opencode.ai/zen/go/v1
OPENAI_MODEL='deepseek/deepseek-v4.1-flash'
reconcile "$H"
expect "$(field "$H" default)" gpt-6.1-sol "unknown pre-ledger value belongs to the operator"

# ── omp: provider follows the endpoint, role follows the model ────────────
O="$fx/omp"
mkdir -p "$O/agent"
cat >"$O/agent/config.yml" <<'YAML'
modelRoles:
  default: opencode-go/deepseek-v4.1-flash
startup:
  quiet: true
YAML
OMP_CONFIG_DIR="$O"
OPENAI_MODEL='deepseek/deepseek-v4.1-flash'
OPENAI_BASE_URL='https://api.commandcode.ai/provider/v1'
opc_omp_seed
expect "$(opc_yaml_field "$O/agent/config.yml" default)" "opc/$OPENAI_MODEL" \
    "legacy opencode-go role must migrate to the seeded provider"
grep -q '^  quiet: true$' "$O/agent/config.yml" || fail "opc_omp_seed clobbered unrelated config keys"
grep -q "baseUrl: $OPENAI_BASE_URL$" "$O/agent/models.yml" || fail "models.yml must carry OPENAI_BASE_URL"
grep -q '^    apiKey: OPENAI_API_KEY$' "$O/agent/models.yml" || fail "models.yml must read the stack key"
grep -q "      - id: $OPENAI_MODEL$" "$O/agent/models.yml" || fail "models.yml must carry the model id verbatim"

# A switch rewrites our own file…
OPENAI_MODEL='Qwen/Qwen3.8-Max'
OMP_MODEL_CONTEXT_WINDOW=200000
opc_omp_seed
expect "$(opc_yaml_field "$O/agent/config.yml" default)" "opc/$OPENAI_MODEL" "omp role follows the model"
grep -q "      - id: $OPENAI_MODEL$" "$O/agent/models.yml" || fail "models.yml did not follow the model"
grep -q '^        contextWindow: 200000$' "$O/agent/models.yml" || fail "optional metadata knob not honoured"

# …but a hand-edited one is left alone, loudly.
printf 'providers:\n  mine:\n    baseUrl: https://example.invalid/v1\n' >"$O/agent/models.yml"
out="$(OPENAI_MODEL='deepseek/deepseek-v4.1-flash' opc_omp_seed 2>&1)"
printf '%s' "$out" | grep -q "changed outside OPC" || fail "hand-edited models.yml must warn"
grep -q 'mine:' "$O/agent/models.yml" || fail "hand-edited models.yml must be preserved"

echo "model-seed: all cases passed"
