#!/usr/bin/env bash
# Connectivity test for the OPC stack — runs against a LIVE stack
# (docker compose up -d first). Never touches the LLM: every probe is
# container state, HTTP endpoint, or a relay-local command.
#
# Waits up to ~5 min for services to become healthy (hermes has a 60s
# start_period), then probes. Exit code: 0 = all PASS, 1 = one or more FAIL.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then echo "FAIL  no .env — run scripts/setup.sh first"; exit 1; fi
. "$(dirname "$0")/../scripts/load-env.sh"; opc_load_env ./.env

PASS=0; FAIL=0
check() { # check <label> <cmd...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  $label"; PASS=$((PASS+1))
  else
    echo "FAIL  $label"; FAIL=$((FAIL+1))
  fi
}
http_ok() { # http_ok <url> [ok-codes...]  → exit 0 if status matches any
  local url="$1"; shift
  local want="${*:-200}"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo 000)"
  for w in $want; do [ "$code" = "$w" ] && return 0; done
  return 1
}
cid_of() { docker compose ps -a -q "$1" 2>/dev/null; } # container id by service name
service_state() { # <service> → healthy|running|exited|… 
  local cid; cid="$(cid_of "$1")"
  [ -n "$cid" ] || { echo missing; return; }
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null
}
service_exitcode() { local cid; cid="$(cid_of "$1")"; docker inspect --format '{{.State.ExitCode}}' "$cid" 2>/dev/null; }

MAIN="buzz-db buzz-redis buzz-minio buzz frontdoor hermes hermes-dashboard paperclip tencentdb-core tencentdb-hub tencentdb-proxy"
ONESHOT="buzz-minio-init buzz-keys buzz-bootstrap tencentdb-bootstrap"

echo "── wait for services (up to 5 min) ──"
for i in $(seq 1 60); do
  ok=1
  for s in $MAIN; do
    st="$(service_state "$s")"
    if [ "$st" != healthy ] && [ "$st" != running ]; then ok=0; break; fi
  done
  [ "$ok" = 1 ] && break
  sleep 5
done
container_alive() { # <service> — healthy, or running when no healthcheck
  local st; st="$(service_state "$1")"
  [ "$st" = healthy ] || [ "$st" = running ]
}
oneshot_ok() { # <service> — exited 0
  [ "$(service_exitcode "$1")" = 0 ]
}
for s in $MAIN; do
  check "container $s ($(service_state "$s"))" container_alive "$s"
done
for s in $ONESHOT; do
  check "oneshot $s (exit 0)" oneshot_ok "$s"
done

echo "── HTTP endpoints (host → published ports) ──"
check "buzz relay REST  :${BUZZ_PORT:-3000}/_readiness" http_ok "http://127.0.0.1:${BUZZ_PORT:-3000}/_readiness" 200
check "hermes dashboard :${HERMES_DASHBOARD_PORT:-9119}/" http_ok "http://127.0.0.1:${HERMES_DASHBOARD_PORT:-9119}/" 200 401 302
check "hermes API       :${HERMES_API_PORT:-8642}/" http_ok "http://127.0.0.1:${HERMES_API_PORT:-8642}/" 200 401 403 404
# Expert agent profiles are served on the same port under /p/<name>.
#
# The 200 below is NOT self-standing: with multiplex OFF the /p/<name> prefix
# is ignored entirely (api_server._resolve_request_profile) and /v1/health is
# registered unconditionally, so it answers 200 for any prefix whatsoever —
# it would pass on a stack with no profiles at all. The row after it is the
# discriminator: an UNKNOWN profile must 404. That only happens when the
# prefix is actually resolved against the loaded profile set, which is
# precisely what GATEWAY_MULTIPLEX_PROFILES=1 plus a seeded
# /opt/data/profiles/<name> buys. Turn multiplex off, or lose the profile
# directory, and the 404 becomes a 200 and this goes red.
# (tests/scientist.sh asserts the credential half — the profile route
# accepts the profile's own key and rejects the default profile's.)
check "hermes scientist :${HERMES_API_PORT:-8642}/p/agt-scientist/" http_ok \
  "http://127.0.0.1:${HERMES_API_PORT:-8642}/p/agt-scientist/v1/health" 200
check "hermes unknown profile :${HERMES_API_PORT:-8642}/p/<none>/ -> 404" http_ok \
  "http://127.0.0.1:${HERMES_API_PORT:-8642}/p/no-such-expert/v1/health" 404
check "paperclip health :${PAPERCLIP_PORT:-3100}/api/health" http_ok "http://127.0.0.1:${PAPERCLIP_PORT:-3100}/api/health" 200
check "tencentdb core   :${TENCENTDB_CORE_PORT:-8420}/health" http_ok "http://127.0.0.1:${TENCENTDB_CORE_PORT:-8420}/health" 200
check "tencentdb panel  :${TENCENTDB_PANEL_PORT:-8125}/" http_ok "http://127.0.0.1:${TENCENTDB_PANEL_PORT:-8125}/" 200 302
check "tencentdb knowl. :${TENCENTDB_KNOWLEDGE_PORT:-8424}/docs" http_ok "http://127.0.0.1:${TENCENTDB_KNOWLEDGE_PORT:-8424}/docs" 200 302
check "tencentdb proxy  :${TENCENTDB_PROXY_PORT:-8096}/" http_ok "http://127.0.0.1:${TENCENTDB_PROXY_PORT:-8096}/" 200 401 403 404

echo "── internal links ──"
# frontdoor (buzz-acp sidecar) must reach the relay with the agent's key —
# same invocation the register loop uses; exit 0 = relay reachable + agent OK.
check "frontdoor → buzz relay (channels list)" \
  docker compose exec -T frontdoor sh -c 'buzz --relay "http://$(printf "%s" "$BUZZ_RELAY_URL" | sed "s#^wss\?://##")" --private-key "$(cat /keys/agent.nsec)" channels list'

echo
echo "result: ${PASS} pass, ${FAIL} fail"
[ "$FAIL" = 0 ]
