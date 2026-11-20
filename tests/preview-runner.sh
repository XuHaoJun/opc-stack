#!/usr/bin/env bash
# Offline gate: opc-preview-run contract + the preview port slice in compose.
set -u
cd "$(dirname "$0")/.."
IMG="${IMAGE_PREFIX:-opc}/paperclip:local"
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

run() { # run <dir-script> [PORT]
  docker run --rm --network none --entrypoint sh "${@:2}" "$IMG" -c "$1"
}

err=$(run 'd=$(mktemp -d); cd "$d"; opc-preview-run' 2>&1 >/dev/null); rc=$?
[ "$rc" = 64 ] && ok "missing entrypoint exits 64" || bad "missing entrypoint exit ${rc} (want 64)"
case "$err" in *.paperclip/preview*) ok "stderr names .paperclip/preview";; *) bad "stderr: ${err}";; esac

out=$(run 'd=$(mktemp -d); cd "$d"; mkdir .paperclip
printf "#!/bin/sh\necho \"\$HOST:\$PORT\"\n" > .paperclip/preview; chmod +x .paperclip/preview
opc-preview-run' -e PORT=21012 2>&1)
[ "$out" = "0.0.0.0:21012" ] && ok "runner execs preview with HOST/PORT" || bad "runner output: ${out}"

cfg=$(docker compose config --format json)
python3 - "$cfg" <<'PY' && ok "compose port slice + env" || bad "compose structure"
import json, sys
c = json.loads(sys.argv[1])["services"]
pub = [p for p in c["paperclip"]["ports"]]
cover = []
for p in pub:
    pu = str(p["published"])
    if "-" in pu:
        a, b = map(int, pu.split("-"))
    else:
        a = b = int(pu)
    cover += range(a, b + 1)
want = list(range(21000, 21016))
assert all(cover.count(x) == 1 for x in want), cover
pe = c["paperclip"]["environment"]
assert pe["DEVENV_HTTP_PORT_COUNT"] == "12" and pe["DEVENV_HTTP_PORT_RANGE_END"] == "21011"
for s in ("frontdoor", "hermes"):
    e = c[s]["environment"]
    assert e["OPC_PREVIEW_PORT_BASE"] == "21012" and e["OPC_PREVIEW_PORT_END"] == "21015", s
    assert "DEVENV_HTTP_PUBLIC_HOST" in e and "PAPERCLIP_PUBLIC_URL" in e, s
PY
exit $fail
