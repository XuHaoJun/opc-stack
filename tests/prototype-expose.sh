#!/usr/bin/env bash
# Offline gate for `prototype expose`: what it writes to Paperclip, with which
# key. A fake curl on PATH records every request and answers from a scratch
# state dir; no Paperclip, no container.
#
# The rule it pins: the run's agent key never carries a runtime-service write
# (Paperclip 403s any agent-key PATCH holding a host command), and the command
# written is always the fixed opc-preview-run — the prototype's repo decides how
# it is served through .paperclip/preview.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $*" >&2; exit 1; }
pass() { echo "PASS  $*"; }

CLI="$PWD/patches/paperclip/prototype/prototype"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
bin="$scratch/bin"; mkdir -p "$bin"

cat >"$bin/curl" <<'CURL'
#!/bin/sh
# Minimal curl stand-in: -X METHOD, -H "Authorization: Bearer K", URL,
# --data-binary @- (body on stdin). Logs "METHOD PATH KEY BODY" per call.
method=GET; key=""; url=""; body=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -H) case "$2" in "Authorization: Bearer "*) key="${2#Authorization: Bearer }" ;; esac; shift 2 ;;
        --data-binary) body="$(cat)"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
path="${url#*/api}"
printf '%s %s %s %s\n' "$method" "$path" "$key" "$body" >>"$FAKE/log"
st="$FAKE/state"
case "$method $path" in
    "GET /companies") echo '[{"id":"c1"}]' ;;
    "GET /companies/c1/projects") echo '[{"id":"p1","name":"demo"}]' ;;
    "GET /projects/p1")
        svcs="$(cat "$st/services")"; rs="$(cat "$st/runtime")"
        jq -nc --argjson s "$svcs" --argjson rs "$rs" '
            {id:"p1",workspaces:[{id:"w1",isPrimary:true,
              runtimeConfig:{workspaceRuntime:{services:$s}},runtimeServices:$rs}]}' ;;
    "PATCH /projects/p1/workspaces/w1")
        [ "$key" = board-key ] || { echo '{"error":"Agent keys cannot modify host-executed workspace commands"}'; exit 22; }
        printf '%s' "$body" | jq -c '.runtimeConfig.workspaceRuntime.services' >"$st/services"; echo '{}' ;;
    "POST /projects/p1/workspaces/w1/runtime-services/"*)
        [ "$key" = board-key ] || exit 22
        if [ "${path##*/}" = stop ]; then echo '[]' >"$st/runtime"
        else jq -nc --argjson p "$(cat "$st/port")" --arg s "$(cat "$st/result")" \
                '[{serviceName:"preview",status:$s,port:$p,updatedAt:"t"}]' >"$st/runtime"; fi
        echo '{}' ;;
    *) echo "unstubbed $method $path" >&2; exit 22 ;;
esac
CURL
printf '#!/bin/sh\nexit 0\n' >"$bin/devenv"
chmod +x "$bin/curl" "$bin/devenv"

export FAKE="$scratch" PATH="$bin:$PATH"
export PROTOTYPE_ROOT="$scratch/protos" BOARD_KEY_FILE="$scratch/board.key"
export PAPERCLIP_API_KEY=agent-key PAPERCLIP_API_URL=http://pc:3100
export PROTOTYPE_POLL_SECONDS=0 PROTOTYPE_START_TIMEOUT=2
printf 'board-key' >"$BOARD_KEY_FILE"
dir="$PROTOTYPE_ROOT/demo"; mkdir -p "$dir/.paperclip" "$scratch/state"
printf 'DEV_PORT=21003\nDEV_URL=http://box:21003\n' >"$dir/.env"

reset() { # services-json [result] [running-port]
    : >"$scratch/log"
    printf '%s' "$1" >"$scratch/state/services"
    echo '[]' >"$scratch/state/runtime"
    printf '%s' "${2:-running}" >"$scratch/state/result"
    printf '%s' "${3:-21003}" >"$scratch/state/port"
    printf '#!/bin/sh\nexec true\n' >"$dir/.paperclip/preview"; chmod +x "$dir/.paperclip/preview"
}
writes() { grep -E '^(PATCH|POST|PUT|DELETE) ' "$scratch/log" || true; }

# ── removed flags fail loudly instead of silently doing the old thing ──
reset '[]'
for args in "expose demo --command x" "expose demo --idle 7d" "create demo --command x" "create demo --idle never"; do
    rc=0; out="$(sh "$CLI" $args 2>&1)" || rc=$?
    [[ "$rc" == 2 ]] || fail "'prototype $args' must exit 2 (got $rc): $out"
done
[[ -z "$(writes)" ]] || fail "a refused flag still wrote: $(writes)"
pass "--command / --idle are refused, nothing written"

# ── no .paperclip/preview: refuse before writing anything ──
reset '[]'; rm -f "$dir/.paperclip/preview"
rc=0; out="$(sh "$CLI" expose demo --start 2>&1)" || rc=$?
[[ "$rc" == 2 ]] || fail "missing .paperclip/preview must exit 2 (got $rc)"
grep -q '.paperclip/preview' <<<"$out" || fail "error does not name .paperclip/preview: $out"
[[ -z "$(writes)" ]] || fail "wrote without a preview script: $(writes)"
pass "missing .paperclip/preview is refused before any write"

# ── register + start: board key, fixed command, preview selector ──
reset '[]'
out="$(sh "$CLI" expose demo --start 2>&1)" || fail "expose --start failed: $out"
grep -q 'http://box:21003' <<<"$out" || fail "expose did not report the URL: $out"
grep -q ' agent-key ' <(writes) && fail "a write used the agent key: $(writes)"
jq -e 'length==1 and .[0].name=="preview" and .[0].command=="opc-preview-run" and .[0].port==21003
    and .[0].expose.urlTemplate=="http://box:21003" and .[0].lifecycle=="shared"
    and (.[0]|has("stopPolicy")|not)' "$scratch/state/services" >/dev/null \
    || fail "registered service wrong: $(cat "$scratch/state/services")"
patch="$(writes | grep '^PATCH ' | cut -d' ' -f4-)"
jq -e '.runtimeConfig | has("desiredState") | not' <<<"$patch" >/dev/null \
    || fail "register PATCH must not set desiredState (start records it): $patch"
start="$(writes | grep '^POST .*/runtime-services/start' | cut -d' ' -f4-)"
jq -e '.serviceIndex==0' <<<"$start" >/dev/null || fail "start lacks the preview selector: $start"
pass "expose --start registers opc-preview-run with the board key and starts only the preview"

# ── re-expose: in place, other services and their indices untouched ──
reset '[{"name":"api","command":"x","port":21005},{"name":"preview","command":"old","port":1}]'
sh "$CLI" expose demo --restart >/dev/null 2>&1 || fail "expose --restart failed"
jq -e 'length==2 and .[0].name=="api" and .[0].command=="x" and .[1].name=="preview"
    and .[1].command=="opc-preview-run" and .[1].port==21003' "$scratch/state/services" >/dev/null \
    || fail "upsert moved or touched other services: $(cat "$scratch/state/services")"
restart="$(writes | grep '^POST .*/runtime-services/restart' | cut -d' ' -f4-)"
jq -e '.serviceIndex==1' <<<"$restart" >/dev/null || fail "restart targeted the wrong service: $restart"
pass "re-expose replaces the preview in place and restarts only it"

# ── already registered and unchanged: no PATCH ──
reset "$(jq -nc '[{name:"preview",command:"opc-preview-run",cwd:".",port:21003,lifecycle:"shared",
    readiness:{type:"http",urlTemplate:"http://127.0.0.1:{{port}}"},expose:{type:"url",urlTemplate:"http://box:21003"}}]')"
sh "$CLI" expose demo --start >/dev/null 2>&1 || fail "expose --start (registered) failed"
writes | grep -q '^PATCH ' && fail "unchanged registration was re-written: $(writes)"
pass "an unchanged registration is not rewritten"

# ── start that fails / falls back to another port is reported, not hidden ──
reset '[]' failed
rc=0; sh "$CLI" expose demo --start >/dev/null 2>&1 || rc=$?
[[ "$rc" == 4 ]] || fail "failed start must exit 4 (got $rc)"
reset '[]' running 39001
rc=0; out="$(sh "$CLI" expose demo --start 2>&1)" || rc=$?
[[ "$rc" == 4 ]] && grep -q 39001 <<<"$out" || fail "port fallback must exit 4 naming the port (rc=$rc): $out"
pass "failed start and port fallback exit 4"

# ── stop: preview only; nothing registered is a no-op ──
reset '[{"name":"api","port":1},{"name":"preview","port":21003}]'
sh "$CLI" expose demo --stop >/dev/null 2>&1 || fail "expose --stop failed"
stop="$(writes | grep '^POST .*/runtime-services/stop' | cut -d' ' -f4-)"
jq -e '.serviceIndex==1' <<<"$stop" >/dev/null || fail "stop targeted the wrong service: $stop"
writes | grep -q '^PATCH ' && fail "stop rewrote the config: $(writes)"
reset '[]'
sh "$CLI" expose demo --stop >/dev/null 2>&1 || fail "stop with nothing registered must succeed"
[[ -z "$(writes)" ]] || fail "stop with nothing registered wrote: $(writes)"
pass "expose --stop targets only the preview; no-op when unregistered"

echo "prototype-expose: ok"
