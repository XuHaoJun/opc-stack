#!/usr/bin/env bash
# Migration gate — runs against a LIVE stack, after an upgrade.
#   tests/migrations.sh [buzz|hermes|paperclip|tencentdb|all]
#
# This gate exists because every silent upgrade failure this stack has hit left
# it HEALTHY. The config ladder ate the front door's system_prompt and the
# container stayed green for 27 hours. A frozen schema overlay would revert an
# upstream module and leave 53 of 54 routes working. `tests/connectivity.sh` is
# green in both. So none of the probes below ask "is it up" — they ask "did the
# migration actually happen, and is what we own still there".
#
# Exit 0 = every assertion held. Exit 1 = at least one did not.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then echo "FAIL  no .env — run scripts/setup.sh first"; exit 1; fi
. "$(dirname "$0")/../scripts/load-env.sh"; opc_load_env ./.env

TARGET="${1:-all}"
PASS=0; FAIL=0
pass() { echo "PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
note() { echo "      $1"; }
section() { printf '\n── %s ──\n' "$1"; }

# `docker compose exec -T` so this works from a script; every command below is
# read-only.
dexec() { docker compose exec -T "$@" 2>/dev/null; }

# log_has <service> <extended-regex> — true when the service log matches.
#
# NOT `docker compose logs <svc> | grep -q`. grep -q exits on the first match,
# `docker compose logs` then dies of SIGPIPE, and `set -o pipefail` reports the
# whole pipeline as failed — so a matching log reads as "no match". On buzz
# (53k log lines) that turned a real "Database migrations complete" into a FAIL,
# and on the two probes below, where a match means TROUBLE, it would have turned
# a real failure into a silent PASS. grep -c consumes all input, so no SIGPIPE.
log_has() {
  local n
  n="$(docker compose logs "$1" 2>/dev/null | grep -cE "$2" || true)"
  [ "${n:-0}" != 0 ]
}

# ── buzz ────────────────────────────────────────────────────────────────
# sqlx embeds the migration set into the relay binary at compile time and
# validates it against _sqlx_migrations on every boot, so "applied count" and
# "files at the pin" must agree exactly. They disagree in two directions and
# both matter: fewer applied = the new migrations did not run; more applied =
# the running binary is OLDER than the volume (a downgrade), which sqlx would
# normally hard-fail on — if we can see it here, something bypassed that.
gate_buzz() {
  section "buzz"
  local files applied allok
  files="$(ls upstream/buzz/migrations/*.sql 2>/dev/null | wc -l | tr -d ' ')"
  applied="$(dexec buzz-db psql -U buzz -d buzz -Atc \
    'select count(*) from _sqlx_migrations;' | tr -d ' \r')"
  allok="$(dexec buzz-db psql -U buzz -d buzz -Atc \
    'select coalesce(bool_and(success), false) from _sqlx_migrations;' | tr -d ' \r')"
  if [ -z "$applied" ]; then
    fail "buzz: cannot read _sqlx_migrations (is buzz-db up?)"
    return
  fi
  if [ "$applied" = "$files" ]; then
    pass "buzz migrations applied: $applied/$files"
  else
    fail "buzz migrations applied: $applied but the pin ships $files"
    note "fewer = migrations did not run; more = the binary is older than the volume"
  fi
  [ "$allok" = t ] && pass "buzz no dirty migration" || \
    fail "buzz has a failed/dirty migration row — repair _sqlx_migrations by hand"
  if log_has buzz 'Database migrations complete'; then
    pass "buzz logged 'Database migrations complete'"
  else
    fail "buzz never logged 'Database migrations complete' — BUZZ_AUTO_MIGRATE may be off"
  fi
}

# ── paperclip ───────────────────────────────────────────────────────────
# Drizzle has no down migrations, and pending is computed as
# available − applied. A DOWNGRADE therefore reports "upToDate" and the old
# server runs happily against the new schema — silently. Counting both sides is
# the only way to see it.
gate_paperclip() {
  section "paperclip"
  local files applied psqlbin
  files="$(ls upstream/paperclip/packages/db/src/migrations/*.sql 2>/dev/null | wc -l | tr -d ' ')"
  # The embedded cluster's credentials are upstream defaults
  # (packages/db/src/migration-runtime.ts) for a loopback-only DB inside the
  # container; PAPERCLIP_DB_* overrides them if it is ever configured.
  applied="$(docker compose exec -T \
      -e PGPASSWORD="${PAPERCLIP_DB_PASSWORD:-paperclip}" paperclip sh -lc '
    b=$(ls -d /nix-seed/store/*postgresql-*/bin 2>/dev/null | head -1)
    [ -n "$b" ] || b=$(dirname "$(command -v psql 2>/dev/null)" 2>/dev/null)
    "$b/psql" -h 127.0.0.1 -p '"${PAPERCLIP_DB_PORT:-54329}"' \
      -U '"${PAPERCLIP_DB_USER:-paperclip}"' -d '"${PAPERCLIP_DB_NAME:-paperclip}"' \
      -Atc "select count(*) from drizzle.__drizzle_migrations;"' 2>/dev/null | tr -d ' \r')"
  if [ -z "$applied" ]; then
    fail "paperclip: cannot read drizzle.__drizzle_migrations (is the embedded cluster up?)"
    return
  fi
  if [ "$applied" = "$files" ]; then
    pass "paperclip migrations applied: $applied/$files"
  elif [ "$applied" -gt "$files" ] 2>/dev/null; then
    fail "paperclip has MORE applied ($applied) than the pin ships ($files) — this is a downgrade"
    note "drizzle reports upToDate in this state; old code is running against a newer schema"
  else
    fail "paperclip migrations applied: $applied but the pin ships $files"
  fi
  if log_has paperclip 'Refusing to start against a stale schema'; then
    fail "paperclip refused to start against a stale schema — read its log"
  else
    pass "paperclip no stale-schema refusal in log"
  fi
}

# ── hermes ──────────────────────────────────────────────────────────────
# Three separate things go wrong here and none of them surface at runtime:
#   1. our seeded _config_version drifting below upstream's default, so every
#      clean install silently runs an unreviewed ladder over our own template;
#   2. a config.yaml stamped below the support floor (12), where hermes refuses
#      to migrate and says so only in a boot line nobody reads;
#   3. reconcile appending a SECOND `platforms:` block, whose symptom is a
#      profile starting zero secondary adapters — with a warning that mentions
#      only api_server.
gate_hermes() {
  section "hermes"
  local upstream_ver literal
  upstream_ver="$(sed -n 's/.*"_config_version": *\([0-9]\+\).*/\1/p' \
    upstream/hermes/hermes_cli/config_defaults.py 2>/dev/null | head -1)"
  literal="$(sed -n 's/^OPC_CONFIG_VERSION=\([0-9]\+\).*/\1/p' \
    patches/hermes/hermes-entrypoint.sh 2>/dev/null | head -1)"
  if [ -n "$upstream_ver" ] && [ "$literal" = "$upstream_ver" ]; then
    pass "hermes seeded _config_version matches upstream default ($literal)"
  else
    fail "hermes seeded _config_version is ${literal:-?}, upstream default is ${upstream_ver:-?}"
    note "clean installs would run _migrate_to_$((literal + 1))..$upstream_ver unattended over our template"
  fi

  local svc home
  for pair in "hermes:/opt/data" "hermes-dashboard:/opt/data" "frontdoor:/opt/data"; do
    svc="${pair%%:*}"; home="${pair##*:}"
    [ -n "$(docker compose ps -q "$svc" 2>/dev/null)" ] || continue
    local bad
    bad="$(dexec "$svc" sh -lc '
      for f in '"$home"'/config.yaml '"$home"'/profiles/*/config.yaml; do
        [ -f "$f" ] || continue
        v=$(sed -n "s/^_config_version: *//p" "$f" | head -1)
        p=$(grep -c "^platforms:" "$f")
        [ -n "$v" ] || echo "$f no-version"
        [ -n "$v" ] && [ "$v" -lt 12 ] 2>/dev/null && echo "$f below-floor:$v"
        [ "$p" -gt 1 ] && echo "$f duplicate-platforms:$p"
      done' )"
    if [ -z "$bad" ]; then
      pass "$svc config.yaml files: versioned at/above the floor, no duplicate platforms block"
    else
      fail "$svc config.yaml problems:"
      printf '%s\n' "$bad" | sed 's/^/      /'
    fi
  done

  # The two things we own in those files, that a migration or a dashboard edit
  # can remove without any runtime symptom.
  if dexec hermes sh -lc 'grep -q "kanban" /opt/data/config.yaml'; then
    pass "hermes kanban still in disabled_toolsets (Paperclip stays the only work plane)"
  else
    fail "hermes config.yaml no longer disables the kanban toolset — invariant 2 broken"
  fi
  if dexec frontdoor sh -lc 'grep -q "system_prompt" /opt/data/config.yaml'; then
    pass "frontdoor system_prompt present"
  else
    fail "frontdoor config.yaml has no system_prompt — this is the 2026-08-17 failure exactly"
  fi
  if dexec hermes sh -lc 'test -f /opt/hermes/SOUL.md && test -s /opt/data/SOUL.md'; then
    pass "hermes SOUL.md present in the agent home"
  else
    fail "hermes SOUL.md missing from the agent home — the delegation rule is not in effect"
  fi
}

# ── tencentdb ───────────────────────────────────────────────────────────
# No version stamp exists anywhere (user_version = 0 on all three sqlite
# files), migrations are detected by probing for columns, and a failed one sets
# degraded = true and turns every write into a no-op. So the probes are: did it
# degrade, do the FTS marker columns exist, and does every route the running
# tag declares actually answer.
gate_tencentdb() {
  section "tencentdb"
  if log_has tencentdb-core '[Dd]egraded|Store init failed|refusing to proceed without functional store'; then
    fail "tencentdb-core logged a degraded/failed store — writes are silently no-ops"
    docker compose logs tencentdb-core 2>/dev/null | \
      grep -iE 'degraded|Store init failed' | tail -3 | sed 's/^/      /'
  else
    pass "tencentdb-core store not degraded"
  fi

  # FTS5 cannot ALTER ADD COLUMN, so upstream drops and rebuilds the index when
  # a marker column is missing. Absent markers = the rebuild did not happen.
  local cols missing=""
  # No sqlite3 CLI in that image and better-sqlite3 is not resolvable from the
  # container root; node 22's built-in node:sqlite reads the file directly.
  cols="$(dexec tencentdb-core node -e '
    const {DatabaseSync} = require("node:sqlite");
    const db = new DatabaseSync("/data/tdai-memory/vectors.db", {readOnly: true});
    console.log(db.prepare("pragma table_info(l1_fts)").all().map(r => r.name).join(" "));
  ' 2>/dev/null)"
  if [ -z "$cols" ]; then
    fail "tencentdb: cannot read l1_fts schema from vectors.db"
  else
    for c in content_original task_id user_id agent_id version; do
      case " $cols " in *" $c "*) ;; *) missing="$missing $c";; esac
    done
    if [ -z "$missing" ]; then
      pass "tencentdb l1_fts carries the v5 marker columns"
    else
      fail "tencentdb l1_fts is missing marker column(s):$missing — the FTS rebuild did not run"
    fi
  fi

  # The route sweep. An empty body against a route whose zod schema exists is a
  # 400; against a route whose schema module lost the export it is a 500,
  # because bind() derefs the schema lazily inside the handler. This is the
  # assertion that catches a build-time overlay reverting upstream's additions
  # — the failure that otherwise shows up as 53 of 54 routes working.
  local router port key routes total=0 bad=0
  router=upstream/tencentdb-agent-memory/MemoryCore/src/metadata/router/v3-meta-router.ts
  port="${TENCENTDB_CORE_PORT:-8420}"
  key="${TENCENTDB_GATEWAY_API_KEY:-}"
  if [ ! -f "$router" ]; then
    fail "tencentdb: cannot find $router to enumerate routes"
    return
  fi
  routes="$(grep -oE '\$\{V3_PREFIX\}/[a-z0-9/_-]+' "$router" | sed 's|${V3_PREFIX}|/v3/meta|' | sort -u)"
  for r in $routes; do
    total=$((total + 1))
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST \
      "http://127.0.0.1:$port$r" -H 'content-type: application/json' \
      -H "authorization: Bearer $key" -d '{}' 2>/dev/null || echo 000)"
    case "$code" in
      5*|000) echo "      5xx  $r -> $code"; bad=$((bad + 1)) ;;
    esac
  done
  if [ "$bad" = 0 ]; then
    pass "tencentdb meta routes answer: $total/$total non-5xx"
  else
    fail "tencentdb $bad of $total meta routes returned 5xx on an empty body"
    note "a 500 here means the route's zod schema is undefined — the schema module lost an export"
  fi

  # The proxy regenerates its config every boot; a stale one means the
  # entrypoint did not run (or the reconcile was reverted).
  if dexec tencentdb-proxy sh -lc 'test -f /data/config.yaml'; then
    pass "tencentdb-proxy config.yaml present"
  else
    fail "tencentdb-proxy has no /data/config.yaml"
  fi
}

case "$TARGET" in
  buzz)      gate_buzz ;;
  paperclip) gate_paperclip ;;
  hermes)    gate_hermes ;;
  tencentdb) gate_tencentdb ;;
  all)       gate_buzz; gate_paperclip; gate_hermes; gate_tencentdb ;;
  *)         echo "usage: tests/migrations.sh [buzz|hermes|paperclip|tencentdb|all]" >&2; exit 1 ;;
esac

printf '\n── %d passed, %d failed ──\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
