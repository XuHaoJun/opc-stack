#!/usr/bin/env bash
# Does every piece of scientist state have an automatic producer?
#
# A fresh `scripts/setup.sh` must produce a fully working expert lane with no
# migration script and no manual step. The trap this guards against: compose
# one-shots are NOT re-run when a container already exists and exited 0, so
# "I re-ran it by hand and it worked" says nothing about a fresh machine.
# Every row below must name a producer that runs unattended on `up`.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# has <label> <file> <pattern>
has() {
    if grep -q -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (missing in $2)"; fi
}

echo "── every artifact has an automatic producer ──"
has "scientist keypair: buzz-keys one-shot"           patches/buzz/generate-keys.sh          'gen scientist'
has "relay membership: buzz-bootstrap one-shot"       patches/buzz/add-member.sh             'for _who in agent scientist'
has "discovery + channels: frontdoor register loop"   patches/buzz/opc-register-agent.sh     'scientist|scientist|'
has "profile skeleton: hermes entrypoint"             patches/hermes/hermes-entrypoint.sh    'opc_seed_expert_profile agt-scientist'
has "SOUL.md: image + boot sync"                      patches/hermes/hermes-entrypoint.sh    'profiles/$_p/SOUL.md'
has "experiment queue: hermes entrypoint"             patches/hermes/hermes-entrypoint.sh    'experiment-queue'
# Asserts the actual default that registers the scientist (agt-scientist as
# an EXTRA_AGENTS entry), not just that the EXTRA_AGENTS mechanism exists —
# the bare variable name still appears in the consumption loop and comments
# even with an empty default, which would make this pass vacuously.
has "memory tenancy: tencentdb-bootstrap one-shot"    patches/tencentdb-agent-memory/MemoryCore/opc-tencentdb-provision.sh 'TENCENTDB_EXTRA_AGENTS:-agt-scientist:Scientist'
has "board agent: paperclip-bootstrap one-shot"       patches/paperclip/opc-paperclip-bootstrap.sh 'SCIENTIST_NAME'
# Asserts the real producer action (the `devenv provision scientist` call),
# not just that a service block named devenv-expert-leases exists somewhere
# in the compose file — that weaker form would still pass if the command
# inside the one-shot were ever changed to provision the wrong tenant.
has "devenv lease: devenv-expert-leases one-shot"     docker-compose.yml                     'devenv provision scientist'
has "api key ships in .env.example"                   .env.example                           'HERMES_SCIENTIST_API_KEY'

echo "── ordering: nothing races its producer ──"
# hermes reads /keys/scientist.nsec; buzz-keys writes it.
if python3 - <<'PYEOF'
import sys, re
svc = open("docker-compose.yml").read()
m = re.search(r"\n  hermes:\n(.*?)(?=\n  [a-z][a-z0-9-]*:\n)", svc, re.S)
sys.exit(0 if m and "buzz-keys:" in m.group(1) else 1)
PYEOF
then ok "hermes depends_on buzz-keys"; else bad "hermes depends_on buzz-keys"; fi
has "entrypoint also waits for the key"  patches/hermes/hermes-entrypoint.sh  'wait_for_keys /keys/paperclip-api.key /keys/tencentdb-admin-user-id /keys/scientist.nsec'

echo "── idempotence: re-running a producer must not duplicate ──"
has "keys: only generates what is absent"    patches/buzz/generate-keys.sh       'already present'
has "cron: guarded by job name"              patches/hermes/hermes-entrypoint.sh 'grep -q "experiment-queue"'
has "board agent: reconciles, not create-only" patches/paperclip/opc-paperclip-bootstrap.sh 'adapterConfig reconciled'
has "agent reconcile is one shared helper"   patches/paperclip/opc-paperclip-bootstrap.sh 'reconcile_agent()'
has "tencentdb: get before create"           patches/tencentdb-agent-memory/MemoryCore/opc-tencentdb-provision.sh 'already exists'

echo
printf 'result: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
