#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. ./scripts/load-env.sh; opc_load_env ./.env

PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }

COMPOSE_JSON="$(docker compose config --format json)"
check "RustFS image is pinned" jq -e '
  .services["devenv-s3"].image ==
  "rustfs/rustfs:1.0.0-rc.3@sha256:800cf3f352a0a27e3275ca854a51f0027975d7acc7a0d52089a35bcc9fcbf0b5"
' <<<"$COMPOSE_JSON"
check "RustFS data uses a named volume" jq -e '
  any(.services["devenv-s3"].volumes[];
      .source == "devenv-s3-data" and .target == "/data")
' <<<"$COMPOSE_JSON"
check "S3 host port is loopback only" jq -e '
  any(.services["devenv-s3"].ports[];
      .target == 9000 and .host_ip == "127.0.0.1")
' <<<"$COMPOSE_JSON"
check "RustFS console is disabled" jq -e '
  .services["devenv-s3"].environment.RUSTFS_CONSOLE_ENABLE == "false" and
  all(.services["devenv-s3"].ports[]; .target != 9001)
' <<<"$COMPOSE_JSON"
check "Paperclip is not health-gated by RustFS" jq -e '
  .services.paperclip.depends_on["devenv-s3"] == null
' <<<"$COMPOSE_JSON"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
