#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0 FAIL=0
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
assert_eq() { local label="$1" want="$2" got="$3"; [ "$want" = "$got" ] && ok "$label" || { bad "$label (want=$want got=$got)"; return 1; }; }
CLI=patches/hermes/opc-paperclip

assert_eq "https repo identity" "github.com/owner/repo" \
  "$($CLI repo normalize https://github.com/Owner/Repo.git | jq -r .identity)"
assert_eq "scp repo identity" "github.com/owner/repo" \
  "$($CLI repo normalize git@github.com:Owner/Repo.git | jq -r .identity)"
assert_eq "short repo URL" "https://github.com/owner/repo" \
  "$($CLI repo normalize Owner/Repo | jq -r .repoUrl)"
if $CLI repo normalize https://gitlab.com/owner/repo >/dev/null 2>&1; then
  bad "unsupported Git host is rejected"
else
  ok "unsupported Git host is rejected"
fi
cmp -s patches/buzz/opc-paperclip patches/hermes/opc-paperclip \
  && ok "CLI copies are identical" || bad "CLI copies are identical"

echo "result: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
