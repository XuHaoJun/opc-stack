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

LEASE_A="s3-gate-a"
LEASE_B="s3-gate-b"
ENV_A="/tmp/${LEASE_A}.env"
ENV_B="/tmp/${LEASE_B}.env"
pc() { docker compose exec -T -u node paperclip "$@"; }
cleanup() {
  pc devenv release "$LEASE_A" >/dev/null 2>&1 || true
  pc devenv release "$LEASE_B" >/dev/null 2>&1 || true
  pc devenv release s3-pg-only >/dev/null 2>&1 || true
  pc devenv release s3-default >/dev/null 2>&1 || true
  pc rm -rf "$ENV_A" "$ENV_B" /tmp/s3-gate-object /tmp/s3-multipart /tmp/s3-pg-only.env /tmp/s3-default.env /tmp/mc-a /tmp/mc-b >/dev/null 2>&1 || true
}
trap cleanup EXIT

check "S3 lease A provisions" pc devenv provision "$LEASE_A" --with s3 --env-file "$ENV_A"
check "S3 lease B provisions" pc devenv provision "$LEASE_B" --with s3 --env-file "$ENV_B"
check "S3 env contract is complete" pc sh -ec '
  f=/tmp/s3-gate-a.env
  for k in AWS_ENDPOINT_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION S3_BUCKET S3_FORCE_PATH_STYLE; do
    grep -q "^${k}=" "$f" || exit 1
  done
'
check "tenant A writes its bucket" pc sh -ec '
  . /tmp/s3-gate-a.env
  export MC_CONFIG_DIR=/tmp/mc-a
  mc alias set tenant "$AWS_ENDPOINT_URL" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" --api S3v4 --path on >/dev/null
  printf gate >/tmp/s3-gate-object
  mc cp /tmp/s3-gate-object "tenant/$S3_BUCKET/object" >/dev/null
'
check "tenant A cannot list tenant B" pc sh -ec '
  . /tmp/s3-gate-a.env; other=$(sed -n "s/^S3_BUCKET=//p" /tmp/s3-gate-b.env)
  export MC_CONFIG_DIR=/tmp/mc-a
  ! mc ls "tenant/$other" >/tmp/cross.out 2>&1 && grep -qi "Access Denied" /tmp/cross.out
'

check "S3-only reprovision is byte-stable" pc sh -ec '
  cp /tmp/s3-gate-a.env /tmp/s3-gate-a.before
  devenv provision s3-gate-a --with s3 --env-file /tmp/s3-gate-a.env >/dev/null
  cmp /tmp/s3-gate-a.before /tmp/s3-gate-a.env
'

check "Postgres-only provision ignores dead S3" docker compose exec -T -u node \
  -e DEVENV_S3_HOST=127.0.0.1 -e DEVENV_S3_PORT=1 paperclip \
  devenv provision s3-pg-only --with postgres --env-file /tmp/s3-pg-only.env

check "default lease remains postgres,valkey" pc sh -ec '
  devenv provision s3-default --env-file /tmp/s3-default.env >/dev/null
  ! grep -q "^S3_" /tmp/s3-default.env
  providers=$(PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql     -h "$DEVENV_PG_HOST" -p "$DEVENV_PG_PORT" -U "$DEVENV_PG_ADMIN_USER"     -d "${DEVENV_CONTROL_DB:-devenv_control}" -tAc     "SELECT array_to_string(providers, '"'"','"'"') FROM devenv_tenant WHERE key = '"'"'s3-default'"'"'")
  [ "$(printf %s "$providers" | tr -d "[:space:]")" = "postgres,valkey" ]
'

check "failed S3 release retains registry truth" docker compose exec -T -u node \
  paperclip sh -ec '
    if DEVENV_S3_HOST=127.0.0.1 DEVENV_S3_PORT=1 devenv release s3-gate-a; then exit 1; fi
    PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql       -h "$DEVENV_PG_HOST" -p "$DEVENV_PG_PORT" -U "$DEVENV_PG_ADMIN_USER"       -d "${DEVENV_CONTROL_DB:-devenv_control}" -tAc       "SELECT s3_bucket IS NOT NULL AND '"'"'s3'"'"' = ANY(providers)
         FROM devenv_tenant WHERE key = '"'"'s3-gate-a'"'"'" | grep -q t
  '

check "dead S3 provision exits 4 without state" docker compose exec -T -u node \
  paperclip sh -ec '
    rm -f /tmp/s3-dead.env
    set +e
    DEVENV_S3_HOST=127.0.0.1 DEVENV_S3_PORT=1       devenv provision s3-dead --with s3 --env-file /tmp/s3-dead.env >/tmp/s3-dead.out 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 4 ] && [ ! -e /tmp/s3-dead.env ]
    rows=$(PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql       -h "$DEVENV_PG_HOST" -p "$DEVENV_PG_PORT" -U "$DEVENV_PG_ADMIN_USER"       -d "${DEVENV_CONTROL_DB:-devenv_control}" -tAc       "SELECT count(*) FROM devenv_tenant WHERE key = '"'"'s3-dead'"'"'")
    [ "$(printf %s "$rows" | tr -d "[:space:]")" = 0 ]
  '

check "devenv list ignores dead S3" docker compose exec -T -u node \
  -e DEVENV_S3_HOST=127.0.0.1 -e DEVENV_S3_PORT=1 paperclip devenv list

check "Postgres-only release ignores dead S3" docker compose exec -T -u node \
  -e DEVENV_S3_HOST=127.0.0.1 -e DEVENV_S3_PORT=1 paperclip \
  devenv release s3-pg-only

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
