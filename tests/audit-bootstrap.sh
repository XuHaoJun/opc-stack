#!/usr/bin/env bash
# Does every piece of scientist state have an automatic producer?
#
# A fresh `scripts/setup.sh` must produce a fully working expert lane with no
# migration script and no manual step. The trap this guards against: compose
# one-shots are NOT re-run when a container already exists and exited 0, so
# "I re-ran it by hand and it worked" says nothing about a fresh machine.
# Every row below must name a producer that runs unattended on `up`.
#
# WHAT THIS IS NOT. This suite is a STATIC audit of `patches/` and
# `docker-compose.yml`. The rehearsal that actually proves the open-box claim
# is `tests/fresh-install.sh` — it clones this repo into its own
# compose project, ports and relay and runs `scripts/setup.sh` for real,
# BESIDE the live stack (doing it in place would destroy the live community,
# board, memories, prototypes and leases). Until that has been run, a green
# run here is EVIDENCE, NOT PROOF. Specifically, a green run cannot catch:
#   - a producer that exists in the file but is never invoked at runtime
#     (a role gate that never takes the seeding branch, a function defined and
#     never called, a compose service nothing depends on);
#   - a producer that is invoked, exits 0, and did nothing (an API call that
#     404s behind `|| true`, a `curl` whose body says "error" with status 200);
#   - a producer that runs and writes the WRONG VALUE (right key name, wrong
#     key; right agent, wrong model/adapter config);
#   - `patches/` → `upstream/` drift: every path below is read out of
#     `patches/`, but the images are built from `upstream/<proj>/opc/`, which
#     is only refreshed by `scripts/prepare.sh`. An un-prepared tree passes
#     this audit and ships the old code;
#   - ordering edges nobody wrote a row for — only the two edges in the
#     "ordering" section are checked, and only as declared, not as raced.
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

# hasall <label> <file> <pattern>...  — every pattern must be present.
# Used where the property is "two call sites share one thing", which a single
# grep cannot express: matching the definition alone says nothing about who
# calls it.
hasall() {
    _label="$1"; _file="$2"; shift 2
    for _pat in "$@"; do
        if ! grep -q -- "$_pat" "$_file" 2>/dev/null; then
            bad "$_label (missing in $_file: $_pat)"; return
        fi
    done
    ok "$_label"
}

echo "── every artifact has an automatic producer ──"
has "scientist keypair: buzz-keys one-shot"           patches/buzz/generate-keys.sh          'gen scientist'
has "relay membership: buzz-bootstrap one-shot"       patches/buzz/add-member.sh             'for _who in agent scientist'
has "discovery + channels: frontdoor register loop"   patches/buzz/opc-register-agent.sh     'scientist|scientist|'
has "profile skeleton: hermes entrypoint"             patches/hermes/hermes-entrypoint.sh    'opc_seed_expert_profile agt-scientist'
# The seeding call above exists — but during implementation it moved behind a
# container-role gate, and a gate whose condition is replaced by `true` seeds
# NOTHING in EITHER container while every existence row stays green (that is
# how this row came to be written). The gate's shape defeats a naive grep: the
# TRUE branch is the dashboard skip and the seeding lives in the `else` arm,
# so "the file contains both the gate and the call" is satisfied by a gate
# that never reaches it. Assert the structure instead: the condition is the
# role predicate applied to the container argv, the skip arm does no seeding,
# and the seeding is in the arm the gateway container takes.
if python3 - <<'GATEEOF'
import re, sys
src = open("patches/hermes/hermes-entrypoint.sh").read()
m = re.search(
    r'\nif opc_is_dashboard_container "\$@"; then\n'
    r'((?:(?!\nfi\n).)*?)\nelse\n((?:(?!\nfi\n).)*?)\nfi\n',
    src, re.S)
if not m:
    sys.exit(1)                                    # gate rewritten or removed
skip_arm, gateway_arm = m.group(1), m.group(2)
sys.exit(0 if "opc_seed_expert_profile" not in skip_arm             # arms not swapped
         and "opc_seed_expert_profile agt-scientist" in gateway_arm  # gateway seeds
         else 1)
GATEEOF
then ok "expert seeding runs on the gateway (non-dashboard) arm"
else bad "expert seeding runs on the gateway (non-dashboard) arm"; fi
has "SOUL.md: image + boot sync"                      patches/hermes/hermes-entrypoint.sh    'profiles/$_p/SOUL.md'
# `--name experiment-queue`, not the bare job name: the bare name also
# appears in the comment block above the seeding code, so deleting the code
# and keeping the comment left this row green (RED-tested, fix round 1).
has "experiment queue: hermes entrypoint"             patches/hermes/hermes-entrypoint.sh    '--name experiment-queue'
# Asserts the actual default that registers the scientist (agt-scientist as
# an EXTRA_AGENTS entry), not just that the EXTRA_AGENTS mechanism exists —
# the bare variable name still appears in the consumption loop and comments
# even with an empty default, which would make this pass vacuously.
has "memory tenancy: tencentdb-bootstrap one-shot"    patches/tencentdb-agent-memory/MemoryCore/opc-tencentdb-provision.sh 'TENCENTDB_EXTRA_AGENTS:-agt-scientist:Scientist'
# The CALL, not the variable: `SCIENTIST_NAME` also matches its own
# declaration near the top of the script, so deleting the reconcile call
# entirely left this row green (RED-tested, fix round 1).
has "board agent: paperclip-bootstrap one-shot"       patches/paperclip/opc-paperclip-bootstrap.sh 'reconcile_agent "$SCIENTIST_NAME" hermes_gateway sci_desired_config'
hasall "executor identity and prompt are reconciled" patches/paperclip/opc-paperclip-bootstrap.sh \
    'DEFAULT_EXECUTOR_NAME="Fullstack Engineer"' \
    'LEGACY_EXECUTOR_NAME="OMP Engineer"' \
    'api_patch_raw "/agents/$agent_id"' \
    'reconcile_agent_instructions "$agent_id" "$FULLSTACK_PROMPT"'
hasall "Prototyper prompt is reconciled" patches/paperclip/opc-paperclip-bootstrap.sh \
    'reconcile_agent_instructions "$_prototyper_id" "$PROTOTYPER_PROMPT"'
has "coding-agent prompts ship in the Paperclip image" patches/paperclip/Dockerfile \
    'COPY opc/agent-prompts/ /opt/opc-agent-prompts/'
hasall "managed prompts clear legacy prompt authority" patches/paperclip/opc-paperclip-bootstrap.sh \
    'api_get "/agents/$_rai_id"' \
    'has("promptTemplate")' \
    'has("bootstrapPromptTemplate")'
hasall "engineering routing supports custom executor names" patches/buzz/skills/paperclip-api/SKILL.md \
    'role == "engineer"' \
    'exactly one'
hasall "Hermes knows Paperclip workspace modes" patches/buzz/skills/paperclip-api/SKILL.md \
    'shared_workspace' 'isolated_workspace' 'operator_branch' 'adapter_default' \
    'reuse_existing' 'git_worktree' 'project_primary'
hasall "Hermes knows concurrency scopes" patches/buzz/skills/paperclip-api/SKILL.md \
    'maxConcurrentRuns' 'agent-global' 'sharedWorkspaceConcurrency' 'serialize'
hasall "Hermes uses deterministic ticket routing" patches/buzz/skills/paperclip-api/SKILL.md \
    'opc-paperclip engineering-ticket create' \
    'opc-paperclip prototype-ticket create'
hasall "workspace changes require direct operator authority" patches/buzz/skills/paperclip-api/SKILL.md \
    'direct operator request' 'memory'
has "frontdoor installs Paperclip CLI" patches/buzz/Dockerfile \
    'COPY opc/opc-paperclip /usr/local/bin/opc-paperclip'
has "gateway installs Paperclip CLI" patches/hermes/Dockerfile \
    'COPY opc/opc-paperclip /usr/local/bin/opc-paperclip'
hasall "Paperclip CLI copies are drift guarded" scripts/prepare.sh \
    'check_identical "paperclip CLI (buzz/hermes)"' \
    'patches/buzz/opc-paperclip' \
    'patches/hermes/opc-paperclip'
hasall "Paperclip isolated workspaces are enabled" patches/paperclip/opc-paperclip-bootstrap.sh \
    'enableIsolatedWorkspaces' \
    '/instance/settings/experimental'
hasall "Fullstack concurrency has a managed default" patches/paperclip/opc-paperclip-bootstrap.sh \
    'FULLSTACK_MAX_CONCURRENT_RUNS_DEFAULT=4' \
    'fullstackMaxConcurrentRuns' \
    'maxConcurrentRuns'
# Asserts the real producer action, not just that a service block named
# devenv-expert-leases exists somewhere in the compose file. The full
# invocation (with --env-file) is required because the bare
# `devenv provision scientist` also matches the WARNING echo in the failure
# branch, so pointing the real command at another tenant left this row green
# (RED-tested, fix round 1).
has "devenv lease: devenv-expert-leases one-shot"     docker-compose.yml                     'devenv provision scientist --env-file /keys/devenv-scientist.env'
has "devenv S3 durable volume" docker-compose.yml 'devenv-s3-data:/data'
has "devenv S3 root credential source" docker-compose.yml 'DEVENV_S3_ROOT_PASSWORD'
has "devenv S3 schema producer" patches/paperclip/devenv/bootstrap.sql 'ADD COLUMN IF NOT EXISTS s3_bucket'
has "paperclip carries pinned mc" patches/paperclip/Dockerfile 'RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349e'
has "devenv RabbitMQ durable volume" docker-compose.yml 'devenv-rabbitmq-data:/var/lib/rabbitmq'
has "devenv RabbitMQ admin credential source" docker-compose.yml 'DEVENV_RABBITMQ_ADMIN_PASSWORD'
has "devenv RabbitMQ schema producer" patches/paperclip/devenv/bootstrap.sql 'ADD COLUMN IF NOT EXISTS rabbitmq_vhost'
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
# Both CALL SITES, not just the definition: a row that only matches
# `reconcile_agent()` says the helper exists, never that both agents go
# through it — per-agent copy-pasted reconciliation would keep it green.
hasall "agent reconcile is one shared helper"   patches/paperclip/opc-paperclip-bootstrap.sh \
    'reconcile_agent()' \
    'reconcile_agent "$PROTOTYPER_NAME" claude_local proto_desired_config' \
    'reconcile_agent "$SCIENTIST_NAME" hermes_gateway sci_desired_config'
# Scoped to ensure_agent's body and to the ORDER of the two calls. The bare
# string `already exists` is also printed by the TEAM branch higher up the
# file, so gutting the agent branch's guard left this row green (RED-tested,
# fix round 1).
if python3 - <<'TDBEOF'
import re, sys
src = open("patches/tencentdb-agent-memory/MemoryCore/opc-tencentdb-provision.sh").read()
m = re.search(r"\nensure_agent\(\) \{.*?\n\}\n", src, re.S)
if not m:
    sys.exit(1)
body = m.group(0)
get, create = body.find("/v3/meta/agent/get"), body.find("/v3/meta/agent/create")
sys.exit(0 if get != -1 and create != -1 and get < create
         and "already exists" in body else 1)
TDBEOF
then ok "tencentdb: get before create"
else bad "tencentdb: get before create"; fi

echo
printf 'result: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
