#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. ./scripts/load-env.sh; opc_load_env ./.env

PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }

COMPOSE_JSON="$(docker compose config --format json)"
check "RabbitMQ image is pinned" jq -e '
  .services["devenv-rabbitmq"].image ==
  "rabbitmq:4.3.5-management-alpine@sha256:a1a5dd841347af3e32355fd58ac530e831fd394c49e299f862e2fd4ab331cd79"
' <<<"$COMPOSE_JSON"
check "RabbitMQ data uses a named volume" jq -e '
  any(.services["devenv-rabbitmq"].volumes[];
      .source == "devenv-rabbitmq-data" and .target == "/var/lib/rabbitmq")
' <<<"$COMPOSE_JSON"
check "RabbitMQ node identity survives container recreation" jq -e '
  .services["devenv-rabbitmq"].hostname == "devenv-rabbitmq"
' <<<"$COMPOSE_JSON"
check "RabbitMQ AMQP host port is loopback only" jq -e '
  any(.services["devenv-rabbitmq"].ports[];
      .target == 5672 and .host_ip == "127.0.0.1")
' <<<"$COMPOSE_JSON"
check "RabbitMQ management API is internal only" jq -e '
  all(.services["devenv-rabbitmq"].ports[]; .target != 15672)
' <<<"$COMPOSE_JSON"
check "Paperclip is not health-gated by RabbitMQ" jq -e '
  .services.paperclip.depends_on["devenv-rabbitmq"] == null
' <<<"$COMPOSE_JSON"
check "Paperclip carries the AMQP client tools" grep -Eq \
  'apt-get install .*amqp-tools|postgresql-client redis-tools amqp-tools' patches/paperclip/Dockerfile
check "RabbitMQ lease is visible in the control schema" grep -q \
  'rabbitmq_vhost.*text UNIQUE' patches/paperclip/devenv/bootstrap.sql
check "podenv routes RabbitMQ images to devenv" sh -c '
  . patches/paperclip/devenv/shared.sh
  [ "$(devenv_provider_for_family rabbitmq)" = rabbitmq ]
'

if [ "$FAIL" -ne 0 ]; then
  printf '\n%d passed, %d failed (static preflight)\n' "$PASS" "$FAIL"
  exit 1
fi

LEASE_A="rabbitmq-gate-a"
LEASE_B="rabbitmq-gate-b"
ENV_A="/tmp/${LEASE_A}.env"
ENV_B="/tmp/${LEASE_B}.env"
pc() { docker compose exec -T -u node paperclip "$@"; }
wait_rabbitmq_ready() {
  for _ in $(seq 1 30); do
    if pc sh -c \
        'curl -fsS -u "$DEVENV_RABBITMQ_ADMIN_USER:$DEVENV_RABBITMQ_ADMIN_PASSWORD" "http://$DEVENV_RABBITMQ_HOST:$DEVENV_RABBITMQ_API_PORT/api/health/checks/ready-to-serve-clients"' \
        >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
cleanup() {
  pc devenv release "$LEASE_A" >/dev/null 2>&1 || true
  pc devenv release "$LEASE_B" >/dev/null 2>&1 || true
  pc devenv release rabbitmq-pg-only >/dev/null 2>&1 || true
  pc devenv release rabbitmq-default >/dev/null 2>&1 || true
  pc rm -f "$ENV_A" "$ENV_B" /tmp/rabbitmq-gate-a.before /tmp/rabbitmq-cross.out /tmp/rabbitmq-dead.env /tmp/rabbitmq-dead.out /tmp/rabbitmq-pg-only.env /tmp/rabbitmq-default.env >/dev/null 2>&1 || true
}
trap cleanup EXIT
check "RabbitMQ is ready before lease tests" wait_rabbitmq_ready

check "RabbitMQ lease A provisions" pc devenv provision "$LEASE_A" --with rabbitmq --env-file "$ENV_A"
check "RabbitMQ lease B provisions" pc devenv provision "$LEASE_B" --with rabbitmq --env-file "$ENV_B"
check "RabbitMQ env contract is AMQP_URL" pc sh -ec '
  grep -Eq "^AMQP_URL=amqp://devenv_rabbitmq_gate_a:[0-9a-f]{32}@devenv-rabbitmq:5672/devenv_rabbitmq_gate_a$" /tmp/rabbitmq-gate-a.env
'
check "tenant users have no global management tags" pc sh -ec '
  curl -fsS -u "$DEVENV_RABBITMQ_ADMIN_USER:$DEVENV_RABBITMQ_ADMIN_PASSWORD" \
    "http://$DEVENV_RABBITMQ_HOST:$DEVENV_RABBITMQ_API_PORT/api/users/devenv_rabbitmq_gate_a" \
    | jq -e ".tags == []"
'
check "tenant A has permissions only on its vhost" pc sh -ec '
  rows=$(curl -fsS -u "$DEVENV_RABBITMQ_ADMIN_USER:$DEVENV_RABBITMQ_ADMIN_PASSWORD" \
    "http://$DEVENV_RABBITMQ_HOST:$DEVENV_RABBITMQ_API_PORT/api/users/devenv_rabbitmq_gate_a/permissions")
  [ "$(printf "%s" "$rows" | jq length)" -eq 1 ]
  printf "%s" "$rows" | jq -e '"'"'.[0] | .vhost == "devenv_rabbitmq_gate_a" and .configure == ".*" and .write == ".*" and .read == ".*"'"'"'
'
check "tenant vhost limits are installed" pc sh -ec '
  limits=$(curl -fsS -u "$DEVENV_RABBITMQ_ADMIN_USER:$DEVENV_RABBITMQ_ADMIN_PASSWORD" \
    "http://$DEVENV_RABBITMQ_HOST:$DEVENV_RABBITMQ_API_PORT/api/vhost-limits/devenv_rabbitmq_gate_a")
  printf "%s" "$limits" | jq -e --argjson c "$DEVENV_RABBITMQ_MAX_CONNECTIONS" --argjson q "$DEVENV_RABBITMQ_MAX_QUEUES" '"'"'
    .[0].value["max-connections"] == $c and
    .[0].value["max-queues"] == $q
  '"'"'
'
check "tenant A publishes and consumes in its vhost" pc sh -ec '
  . /tmp/rabbitmq-gate-a.env
  rest=${AMQP_URL#amqp://}; creds=${rest%@*}; target=${rest#*@}
  user=${creds%%:*}; password=${creds#*:}; server=${target%%/*}; vhost=${target#*/}
  args="-s $server --vhost $vhost --username $user --password $password"
  amqp-declare-queue $args -d -q gate >/dev/null
  amqp-publish $args -r gate -b rabbitmq-gate
  [ "$(amqp-get $args -q gate)" = rabbitmq-gate ]
  amqp-publish $args -p -r gate -b rabbitmq-survives-recreate
'
check "tenant A cannot connect to tenant B vhost" pc sh -ec '
  . /tmp/rabbitmq-gate-a.env
  rest=${AMQP_URL#amqp://}; creds=${rest%@*}; target=${rest#*@}
  user=${creds%%:*}; password=${creds#*:}; server=${target%%/*}
  ! amqp-declare-queue -s "$server" --vhost devenv_rabbitmq_gate_b \
      --username "$user" --password "$password" -d -q forbidden >/tmp/rabbitmq-cross.out 2>&1
  grep -Eq "NOT_ALLOWED - access to vhost .* refused" /tmp/rabbitmq-cross.out
'
check "RabbitMQ force-recreate succeeds" docker compose up -d --force-recreate devenv-rabbitmq
check "RabbitMQ returns healthy" wait_rabbitmq_ready
check "queue, message, and IAM survive recreate" pc sh -ec '
  . /tmp/rabbitmq-gate-a.env
  rest=${AMQP_URL#amqp://}; creds=${rest%@*}; target=${rest#*@}
  user=${creds%%:*}; password=${creds#*:}; server=${target%%/*}; vhost=${target#*/}
  args="-s $server --vhost $vhost --username $user --password $password"
  [ "$(amqp-get $args -q gate)" = rabbitmq-survives-recreate ]
'
check "RabbitMQ-only reprovision is byte-stable" pc sh -ec '
  cp /tmp/rabbitmq-gate-a.env /tmp/rabbitmq-gate-a.before
  devenv provision rabbitmq-gate-a --with rabbitmq --env-file /tmp/rabbitmq-gate-a.env >/dev/null
  cmp /tmp/rabbitmq-gate-a.before /tmp/rabbitmq-gate-a.env
'
check "Postgres-only provision ignores dead RabbitMQ" docker compose exec -T -u node \
  -e DEVENV_RABBITMQ_HOST=127.0.0.1 -e DEVENV_RABBITMQ_API_PORT=1 paperclip \
  devenv provision rabbitmq-pg-only --with postgres --env-file /tmp/rabbitmq-pg-only.env
check "default lease remains postgres,valkey" pc sh -ec '
  devenv provision rabbitmq-default --env-file /tmp/rabbitmq-default.env >/dev/null
  ! grep -q "^AMQP_URL=" /tmp/rabbitmq-default.env
  providers=$(PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql \
    -h "$DEVENV_PG_HOST" -p "$DEVENV_PG_PORT" -U "$DEVENV_PG_ADMIN_USER" \
    -d "${DEVENV_CONTROL_DB:-devenv_control}" -tAc \
    "SELECT array_to_string(providers, '"'"','"'"') FROM devenv_tenant WHERE key = '"'"'rabbitmq-default'"'"'")
  [ "$(printf %s "$providers" | tr -d "[:space:]")" = "postgres,valkey" ]
'
check "failed RabbitMQ release retains registry truth" docker compose exec -T -u node paperclip sh -ec '
  if DEVENV_RABBITMQ_HOST=127.0.0.1 DEVENV_RABBITMQ_API_PORT=1 devenv release rabbitmq-gate-a; then exit 1; fi
  PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql \
    -h "$DEVENV_PG_HOST" -p "$DEVENV_PG_PORT" -U "$DEVENV_PG_ADMIN_USER" \
    -d "${DEVENV_CONTROL_DB:-devenv_control}" -tAc \
    "SELECT rabbitmq_vhost IS NOT NULL AND '"'"'rabbitmq'"'"' = ANY(providers)
       FROM devenv_tenant WHERE key = '"'"'rabbitmq-gate-a'"'"'" | grep -q t
'
check "dead RabbitMQ provision exits 4 without state" docker compose exec -T -u node paperclip sh -ec '
  rm -f /tmp/rabbitmq-dead.env
  set +e
  DEVENV_RABBITMQ_HOST=127.0.0.1 DEVENV_RABBITMQ_API_PORT=1 \
    devenv provision rabbitmq-dead --with rabbitmq --env-file /tmp/rabbitmq-dead.env >/tmp/rabbitmq-dead.out 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 4 ] && [ ! -e /tmp/rabbitmq-dead.env ]
  rows=$(PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql \
    -h "$DEVENV_PG_HOST" -p "$DEVENV_PG_PORT" -U "$DEVENV_PG_ADMIN_USER" \
    -d "${DEVENV_CONTROL_DB:-devenv_control}" -tAc \
    "SELECT count(*) FROM devenv_tenant WHERE key = '"'"'rabbitmq-dead'"'"'")
  [ "$(printf %s "$rows" | tr -d "[:space:]")" = 0 ]
'
check "devenv list ignores dead RabbitMQ" docker compose exec -T -u node \
  -e DEVENV_RABBITMQ_HOST=127.0.0.1 -e DEVENV_RABBITMQ_API_PORT=1 paperclip devenv list
check "Postgres-only release ignores dead RabbitMQ" docker compose exec -T -u node \
  -e DEVENV_RABBITMQ_HOST=127.0.0.1 -e DEVENV_RABBITMQ_API_PORT=1 paperclip \
  devenv release rabbitmq-pg-only

check "tenant A release succeeds" pc devenv release "$LEASE_A"
check "release removes only tenant A" pc sh -ec '
  base="http://$DEVENV_RABBITMQ_HOST:$DEVENV_RABBITMQ_API_PORT/api"
  auth="$DEVENV_RABBITMQ_ADMIN_USER:$DEVENV_RABBITMQ_ADMIN_PASSWORD"
  [ "$(curl -sS -u "$auth" -o /dev/null -w "%{http_code}" "$base/vhosts/devenv_rabbitmq_gate_a")" = 404 ]
  [ "$(curl -sS -u "$auth" -o /dev/null -w "%{http_code}" "$base/users/devenv_rabbitmq_gate_a")" = 404 ]
  curl -fsS -u "$auth" "$base/vhosts/devenv_rabbitmq_gate_b" >/dev/null
  curl -fsS -u "$auth" "$base/users/devenv_rabbitmq_gate_b" >/dev/null
'
check "tenant B still connects after A release" pc sh -ec '
  . /tmp/rabbitmq-gate-b.env
  rest=${AMQP_URL#amqp://}; creds=${rest%@*}; target=${rest#*@}
  user=${creds%%:*}; password=${creds#*:}; server=${target%%/*}; vhost=${target#*/}
  amqp-declare-queue -s "$server" --vhost "$vhost" --username "$user" --password "$password" -d -q still-live >/dev/null
'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
