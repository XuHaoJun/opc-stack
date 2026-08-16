#!/usr/bin/env bash
# Connectivity test for the OPC stack — runs against a LIVE stack
# (docker compose up -d first). Never touches the LLM: every probe is
# container state, HTTP endpoint, or a relay-local command.
#
# Exit code: 0 = all PASS, 1 = one or more FAIL.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then echo "FAIL  no .env — run scripts/setup.sh first"; exit 1; fi
set -a; . ./.env; set +a

PASS=0; FAIL=0
check() { # check <label> <cmd...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  $label"; PASS=$((PASS+1))
  else
    echo "FAIL  $label"; FAIL=$((FAIL+1))
  fi
}
http_ok() { # http_ok <url> [ok-codes...]  → exit 0 if status matches
  local url="$1"; shift
  local want="${1:-200}"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo 000)"
  for w in $want; do [ "$code" = "$w" ] && return 0; done
  return 1
}
container_alive() { # healthy, or running when no healthcheck
  [ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null)" = "healthy" ] \
    || [ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null)" = "running" ]
}

echo "── container state ──"
for c in buzz-db buzz-redis buzz-minio buzz-keys buzz buzz-bootstrap frontdoor hermes paperclip tencentdb-core tencentdb-hub tencentdb-proxy; do
  check "container $c" container_alive "$c"
done

echo "── HTTP endpoints (host → published ports) ──"
check "buzz relay REST  :${BUZZ_PORT:-3000}/_readiness" http_ok "http://127.0.0.1:${BUZZ_PORT:-3000}/_readiness" 200
check "hermes dashboard :${HERMES_DASHBOARD_PORT:-9119}/" http_ok "http://127.0.0.1:${HERMES_DASHBOARD_PORT:-9119}/" 200 401 302
check "hermes API       :${HERMES_API_PORT:-8642}/" http_ok "http://127.0.0.1:${HERMES_API_PORT:-8642}/" 200 401 403 404
check "paperclip health :${PAPERCLIP_PORT:-3100}/api/health" http_ok "http://127.0.0.1:${PAPERCLIP_PORT:-3100}/api/health" 200
check "tencentdb core   :${TENCENTDB_CORE_PORT:-8420}/health" http_ok "http://127.0.0.1:${TENCENTDB_CORE_PORT:-8420}/health" 200
check "tencentdb panel  :${TENCENTDB_PANEL_PORT:-8125}/" http_ok "http://127.0.0.1:${TENCENTDB_PANEL_PORT:-8125}/" 200 302
check "tencentdb knowl. :${TENCENTDB_KNOWLEDGE_PORT:-8424}/docs" http_ok "http://127.0.0.1:${TENCENTDB_KNOWLEDGE_PORT:-8424}/docs" 200 302
check "tencentdb proxy  :${TENCENTDB_PROXY_PORT:-8096}/" http_ok "http://127.0.0.1:${TENCENTDB_PROXY_PORT:-8096}/" 200 401 403 404

echo "── internal links ──"
# frontdoor (buzz-acp sidecar) must reach the relay; buzz-cli lists channels
# through the relay's REST API. Exit 0 = relay reachable + agent can talk.
check "frontdoor → buzz relay (channels list)" docker compose exec -T frontdoor buzz channels list

echo
echo "result: ${PASS} pass, ${FAIL} fail"
[ "$FAIL" = 0 ]
