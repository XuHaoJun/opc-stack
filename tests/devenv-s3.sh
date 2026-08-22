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
  pc rm -rf "$ENV_A" "$ENV_B" /tmp/s3-gate-object /tmp/s3-multipart /tmp/s3-pg-only.env /tmp/s3-default.env /tmp/mc-a /tmp/mc-b /tmp/s3-gate-a.before /tmp/s3-dead.env /tmp/s3-dead.out /tmp/cross.out /tmp/cross-put.out /tmp/cross-get.out /tmp/own-delete.out >/dev/null 2>&1 || true
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
check "tenant A reads its object" pc sh -ec '
  . /tmp/s3-gate-a.env; export MC_CONFIG_DIR=/tmp/mc-a
  [ "$(mc cat "tenant/$S3_BUCKET/object")" = gate ]
'
check "tenant A cannot list tenant B" pc sh -ec '
  . /tmp/s3-gate-a.env; other=$(sed -n "s/^S3_BUCKET=//p" /tmp/s3-gate-b.env)
  export MC_CONFIG_DIR=/tmp/mc-a
  ! mc ls "tenant/$other" >/tmp/cross.out 2>&1 && grep -qi "Access Denied" /tmp/cross.out
'
check "tenant A cannot PUT tenant B" pc sh -ec '
  . /tmp/s3-gate-a.env; other=$(sed -n "s/^S3_BUCKET=//p" /tmp/s3-gate-b.env)
  export MC_CONFIG_DIR=/tmp/mc-a
  if mc cp /tmp/s3-gate-object "tenant/$other/forbidden" >/tmp/cross-put.out 2>&1; then exit 1; fi
  grep -Eqi "Access Denied|Insufficient permissions" /tmp/cross-put.out
'
check "tenant A cannot GET tenant B" pc sh -ec '
  . /tmp/s3-gate-a.env; other=$(sed -n "s/^S3_BUCKET=//p" /tmp/s3-gate-b.env)
  export MC_CONFIG_DIR=/tmp/mc-a
  if mc cat "tenant/$other/missing" >/tmp/cross-get.out 2>&1; then exit 1; fi
  grep -Eqi "Access Denied|Insufficient permissions" /tmp/cross-get.out
'
check "tenant A deletes its object" pc sh -ec '
  . /tmp/s3-gate-a.env; export MC_CONFIG_DIR=/tmp/mc-a
  mc rm "tenant/$S3_BUCKET/object" >/dev/null
  if mc stat "tenant/$S3_BUCKET/object" >/tmp/own-delete.out 2>&1; then exit 1; fi
  grep -Eqi "not exist|not found" /tmp/own-delete.out
'
check "tenant multipart upload succeeds" pc sh -ec '
  . /tmp/s3-gate-a.env; export MC_CONFIG_DIR=/tmp/mc-a
  dd if=/dev/zero of=/tmp/s3-multipart bs=1M count=70 status=none
  mc cp /tmp/s3-multipart "tenant/$S3_BUCKET/multipart" >/dev/null
  mc stat --json "tenant/$S3_BUCKET/multipart" | jq -e ".size == 73400320" >/dev/null
'
check "presigned download needs no credentials" pc sh -ec '
  . /tmp/s3-gate-a.env; export MC_CONFIG_DIR=/tmp/mc-a
  url=$(mc share download --json --expire 5m "tenant/$S3_BUCKET/multipart" | jq -er .share)
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  [ "$(curl -fsS "$url" | wc -c)" -eq 73400320 ]
'
check "RustFS force-recreate succeeds" docker compose up -d --force-recreate devenv-s3
ready=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${DEVENV_S3_PORT:-9002}/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" -eq 1 ]; then pass "RustFS returns healthy"; else fail "RustFS returns healthy"; fi
check "object and IAM survive recreate" pc sh -ec '
  . /tmp/s3-gate-a.env; export MC_CONFIG_DIR=/tmp/mc-a
  mc stat "tenant/$S3_BUCKET/multipart" >/dev/null
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

check "tenant A release succeeds" pc devenv release "$LEASE_A"
check "release removes only tenant A" pc sh -ec '
  . /usr/local/lib/devenv/providers/s3.sh
  s3_mc_init
  buckets=$(mc ls devenv --json)
  users=$(mc admin user list devenv --json)
  policies=$(mc admin policy list devenv --json)
  ! printf "%s\n" "$buckets" | jq -e --arg n "devenv-s3-gate-a/" "select(.key == \$n)" >/dev/null
  ! printf "%s\n" "$users" | jq -e --arg n "devenv-s3-gate-a" "select(.accessKey == \$n)" >/dev/null
  ! printf "%s\n" "$policies" | jq -e --arg n "devenv-s3-gate-a" "select(.policy == \$n)" >/dev/null
  printf "%s\n" "$buckets" | jq -e --arg n "devenv-s3-gate-b/" "select(.key == \$n)" >/dev/null
'
check "tenant B still writes after A release" pc sh -ec '
  . /tmp/s3-gate-b.env
  export MC_CONFIG_DIR=/tmp/mc-b
  mc alias set tenant-b "$AWS_ENDPOINT_URL" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" --api S3v4 --path on >/dev/null
  printf still-live | mc pipe "tenant-b/$S3_BUCKET/after-a-release" >/dev/null
  [ "$(mc cat "tenant-b/$S3_BUCKET/after-a-release")" = still-live ]
'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
