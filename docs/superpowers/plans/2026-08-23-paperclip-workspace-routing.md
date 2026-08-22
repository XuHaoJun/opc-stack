# Paperclip Workspace Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Hermes deterministic, lane-aware Paperclip workspace routing: Fullstack Engineer defaults to at most four global concurrent isolated worktrees, while each Prototyper project keeps one persistent shared repository with one runner at a time, and direct operator overrides survive reconciliation.

**Architecture:** A duplicated, drift-guarded `opc-paperclip` shell CLI owns API normalization, lookup, merge, verification, ticket routing, and operator commands in the Buzz and Hermes images. Paperclip bootstrap owns the instance feature and managed Fullstack concurrency default; `prototype create` owns prototype project-policy reconciliation. Hermes' duplicated skill explains the model and invokes the CLI rather than composing stateful curl workflows itself.

**Tech Stack:** POSIX shell/Bash, `curl`, `jq`, Paperclip REST API, Docker Compose, existing shell integration-test harness.

**Spec:** `docs/superpowers/specs/2026-08-23-paperclip-workspace-routing-design.md`

## Global Constraints

- Never edit `upstream/`; all image changes belong under `patches/` and flow through `scripts/prepare.sh`.
- `patches/buzz/opc-paperclip` and `patches/hermes/opc-paperclip` must be byte-identical and executable.
- `patches/buzz/skills/paperclip-api/SKILL.md` and `patches/hermes/skills/paperclip-api/SKILL.md` must remain byte-identical.
- Paperclip remains the only durable writer for projects, workspaces, issues, and agent runtime state.
- `enableIsolatedWorkspaces: true` enables policies; it does not impose one mode on every lane.
- Fullstack Engineer's managed default is agent-global `maxConcurrentRuns = 4`, not four per project.
- Fullstack projects default to `isolated_workspace` plus `git_worktree`; explicit operator overrides survive.
- Prototype projects default to `shared_workspace` plus `project_primary` and `sharedWorkspaceConcurrency: serialize`; they never receive automatic ticket worktrees.
- Direct operator requests may inspect, set, and reset defaults. Recalled memory is not authorization to mutate settings.
- Preserve unknown runtime-config, metadata, project-policy, workspace-metadata, and adapter-config keys during every PATCH.
- Fail closed on missing/ambiguous identity or an unverified write; never guess or destructively roll back a project.
- Tests may delete only records they create and must restore any live agent setting they temporarily change.

---

## File map

### New files

- `patches/buzz/opc-paperclip` — front-door copy of the deterministic Paperclip CLI.
- `patches/hermes/opc-paperclip` — gateway copy; byte-identical to the Buzz copy.
- `tests/paperclip-workspace-routing.sh` — static and live behavioral gate for feature/default/override/routing contracts.
- `tests/fixtures/paperclip-workspace-api.py` — stateful local HTTP fixture for deterministic CLI contract tests without touching the live board.

### Modified files

- `patches/buzz/Dockerfile` — install `/usr/local/bin/opc-paperclip` in `opc-frontdoor`.
- `patches/hermes/Dockerfile` — install `/usr/local/bin/opc-paperclip` in the Hermes runtime image.
- `scripts/prepare.sh` — fail when the two CLI copies drift.
- `patches/paperclip/opc-paperclip-bootstrap.sh` — enable workspace controls and apply/preserve the Fullstack concurrency default.
- `patches/paperclip/prototype/prototype` — apply/preserve prototype project workspace defaults after create/resume.
- `patches/buzz/skills/paperclip-api/SKILL.md` — workspace concepts and CLI workflows.
- `patches/hermes/skills/paperclip-api/SKILL.md` — identical skill copy.
- `tests/audit-bootstrap.sh` — static ownership/drift/install assertions.
- `tests/fresh-install.sh` — run the new live gate in the isolated clean-install rehearsal.
- `SETUP.md` — operator inspection, set, reset, and lane-default commands.

---

### Task 1: CLI foundation, repository identity, packaging, and drift guard

**Files:**
- Create: `patches/buzz/opc-paperclip`
- Create: `patches/hermes/opc-paperclip`
- Create: `tests/fixtures/paperclip-workspace-api.py`
- Create: `tests/paperclip-workspace-routing.sh`
- Modify: `patches/buzz/Dockerfile:151-169,243-251`
- Modify: `patches/hermes/Dockerfile:218-240`
- Modify: `scripts/prepare.sh:37-76`
- Modify: `tests/audit-bootstrap.sh:96-117`

**Interfaces:**
- Consumes: `PAPERCLIP_API_URL`, `PAPERCLIP_API_KEY`, optional readable `$HERMES_HOME/.paperclip-api.key`.
- Produces CLI commands:
  - `opc-paperclip repo normalize <repo>` → one JSON object `{identity, repoUrl, owner, repo}`.
  - `opc-paperclip project workspace show --repo <repo>` → one JSON object describing the unique live project/workspace/policy.
- Produces internal shell functions used by later tasks: `die`, `api_base`, `api_key`, `api_request`, `company_id`, `canonical_repo_json`, `list_projects`, `unique_project_by_repo`, `primary_workspace_json`, `verify_json_field`.
- Test fixture accepts `PAPERCLIP_FIXTURE_STATE=<path>` and listens on a caller-supplied loopback port.

- [ ] **Step 1: Write failing normalization and packaging tests**

Create `tests/paperclip-workspace-routing.sh` with a test harness and the first contract table:

```bash
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
```

Add failing static assertions to `tests/audit-bootstrap.sh`:

```bash
has "frontdoor installs Paperclip CLI" patches/buzz/Dockerfile \
  'COPY opc/opc-paperclip /usr/local/bin/opc-paperclip'
has "gateway installs Paperclip CLI" patches/hermes/Dockerfile \
  'COPY opc/opc-paperclip /usr/local/bin/opc-paperclip'
hasall "Paperclip CLI copies are drift guarded" scripts/prepare.sh \
  'check_identical "paperclip CLI (buzz/hermes)"' \
  'patches/buzz/opc-paperclip' \
  'patches/hermes/opc-paperclip'
```

- [ ] **Step 2: Run the focused tests and observe failure**

Run:

```bash
tests/paperclip-workspace-routing.sh
tests/audit-bootstrap.sh
```

Expected: the first command fails because `patches/hermes/opc-paperclip` does not exist; audit fails on missing Docker/drift strings.

- [ ] **Step 3: Implement the CLI foundation**

Create the Hermes copy first with these invariants:

```sh
#!/bin/sh
set -eu

DEFAULT_API_URL=http://paperclip:3100

die() { printf 'opc-paperclip: %s\n' "$1" >&2; exit "${2:-1}"; }
api_base() {
    _base="${PAPERCLIP_API_URL:-$DEFAULT_API_URL}"
    _base="${_base%/}"; _base="${_base%/api}"
    printf '%s\n' "$_base"
}
api_key() {
    if [ -n "${PAPERCLIP_API_KEY:-}" ]; then printf '%s\n' "$PAPERCLIP_API_KEY"; return; fi
    _mirror="${HERMES_HOME:-/opt/data}/.paperclip-api.key"
    [ -s "$_mirror" ] || die "no runtime-readable Paperclip credential" 4
    cat "$_mirror"
}
api_request() { # METHOD PATH [JSON]
    _method="$1" _path="$2" _body="${3-}"
    if [ -n "$_body" ]; then
        curl -fsS -X "$_method" -H "Authorization: Bearer $(api_key)" \
          -H 'Content-Type: application/json' --data-binary "$_body" \
          "$(api_base)/api$_path"
    else
        curl -fsS -X "$_method" -H "Authorization: Bearer $(api_key)" \
          "$(api_base)/api$_path"
    fi
}
```

Implement `canonical_repo_json` without network calls. Accept only the five spec forms, strip one trailing `.git`, require exactly two nonempty path components, lowercase the identity, and output through `jq -nc` so malformed input cannot inject JSON:

```sh
canonical_repo_json() {
    _raw="$1"
    case "$_raw" in
      git@github.com:*) _path="${_raw#git@github.com:}" ;;
      ssh://git@github.com/*) _path="${_raw#ssh://git@github.com/}" ;;
      https://github.com/*) _path="${_raw#https://github.com/}" ;;
      http://github.com/*) _path="${_raw#http://github.com/}" ;;
      */*) _path="$_raw" ;;
      *) die "unsupported repository identity: $_raw" 2 ;;
    esac
    _path="${_path%.git}"; _path="${_path#/}"; _path="${_path%/}"
    _owner="${_path%%/*}"; _repo="${_path#*/}"
    [ -n "$_owner" ] && [ -n "$_repo" ] && [ "${_repo#*/}" = "$_repo" ] \
      || die "repository must be exactly owner/repo" 2
    _owner_lc="$(printf '%s' "$_owner" | tr '[:upper:]' '[:lower:]')"
    _repo_lc="$(printf '%s' "$_repo" | tr '[:upper:]' '[:lower:]')"
    jq -nc --arg i "github.com/$_owner_lc/$_repo_lc" \
      --arg u "https://github.com/$_owner_lc/$_repo_lc" \
      --arg o "$_owner_lc" --arg r "$_repo_lc" \
      '{identity:$i,repoUrl:$u,owner:$o,repo:$r}'
}
```

Implement project lookup by fetching `GET /companies/<companyId>/projects`, canonicalizing only GitHub `primaryWorkspace.repoUrl`/the `workspaces[] | select(.isPrimary)` fallback, collecting matches, and requiring cardinality one for `project workspace show`. Never match by project display name.

- [ ] **Step 4: Add the stateful HTTP fixture skeleton**

Create `tests/fixtures/paperclip-workspace-api.py` using `http.server.ThreadingHTTPServer`. Persist this JSON shape after each mutation so later tasks can extend endpoints without changing the contract:

```python
state = {
    "experimental": {"enableIsolatedWorkspaces": False},
    "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
    "agents": [],
    "projects": [],
    "issues": [],
}
```

Implement `GET /api/health`, `/api/companies`, `/api/companies/<id>/agents`, `/api/companies/<id>/projects`, `/api/projects/<id>`, and `/api/projects/<id>/workspaces`. Require `Authorization: Bearer fixture-key`; otherwise return 401. Log only method/path, never the token. Flush state with atomic temporary-file replacement after writes.

- [ ] **Step 5: Package both identical copies**

Copy the completed script byte-for-byte to `patches/buzz/opc-paperclip`. Add:

```dockerfile
COPY opc/opc-paperclip /usr/local/bin/opc-paperclip
```

and include it in the existing `chmod +x` command in both Dockerfiles. In `scripts/prepare.sh`, add:

```bash
check_identical "paperclip CLI (buzz/hermes)" \
  patches/buzz/opc-paperclip \
  patches/hermes/opc-paperclip
```

Place the Buzz COPY in the shared `opc-relay` stage so `opc-frontdoor` inherits it; do not add a second copy in stage 7.

- [ ] **Step 6: Run focused tests**

Run:

```bash
tests/paperclip-workspace-routing.sh
tests/audit-bootstrap.sh
scripts/prepare.sh
```

Expected: all three exit 0; `prepare.sh` prints `SAME  paperclip CLI (buzz/hermes)`.

- [ ] **Step 7: Commit**

```bash
git add patches/buzz/opc-paperclip patches/hermes/opc-paperclip \
  patches/buzz/Dockerfile patches/hermes/Dockerfile scripts/prepare.sh \
  tests/fixtures/paperclip-workspace-api.py tests/paperclip-workspace-routing.sh \
  tests/audit-bootstrap.sh
git commit -m "feat: add deterministic Paperclip CLI"
```

---

### Task 2: Workspace feature and managed Fullstack concurrency default

**Files:**
- Modify: `patches/paperclip/opc-paperclip-bootstrap.sh:20-70,179-270`
- Modify: `patches/buzz/opc-paperclip`
- Modify: `patches/hermes/opc-paperclip`
- Modify: `tests/fixtures/paperclip-workspace-api.py`
- Modify: `tests/paperclip-workspace-routing.sh`
- Modify: `tests/audit-bootstrap.sh`

**Interfaces:**
- Consumes Task 1 `api_request`, unique-agent lookup, and fixture state.
- Produces:
  - `opc-paperclip agent concurrency show --role engineer`
  - `opc-paperclip agent concurrency set --role engineer --max <1..50>`
  - `opc-paperclip agent concurrency reset --role engineer`
- Bootstrap metadata contract: `metadata.opcManagedDefaults.fullstackMaxConcurrentRuns` stores the last repository default applied.
- Bootstrap constant: `FULLSTACK_MAX_CONCURRENT_RUNS_DEFAULT=4`.

- [ ] **Step 1: Extend fixture and write failing CLI tests**

Add fixture handlers:

```text
GET   /api/instance/settings/experimental
PATCH /api/instance/settings/experimental
PATCH /api/agents/<id>
```

`PATCH /api/agents/<id>` must JSON-merge top-level supplied fields and return the full updated agent. Seed one engineer:

```json
{
  "id": "00000000-0000-4000-8000-000000000010",
  "name": "Fullstack Engineer",
  "role": "engineer",
  "status": "idle",
  "runtimeConfig": {"heartbeat": {"maxConcurrentRuns": 4}},
  "metadata": {"opcManagedDefaults": {"fullstackMaxConcurrentRuns": 4}}
}
```

Start the fixture in `tests/paperclip-workspace-routing.sh` with a trap, export `PAPERCLIP_API_URL` and `PAPERCLIP_API_KEY=fixture-key`, then assert:

```bash
assert_eq "engineer concurrency show" "4" \
  "$($CLI agent concurrency show --role engineer | jq -r .maxConcurrentRuns)"
$CLI agent concurrency set --role engineer --max 6 >/dev/null
assert_eq "operator concurrency set" "6" \
  "$($CLI agent concurrency show --role engineer | jq -r .maxConcurrentRuns)"
assert_eq "set is marked override" "operator_override" \
  "$($CLI agent concurrency show --role engineer | jq -r .source)"
$CLI agent concurrency reset --role engineer >/dev/null
assert_eq "concurrency reset" "4" \
  "$($CLI agent concurrency show --role engineer | jq -r .maxConcurrentRuns)"
```

Also test max 0 and 51 fail before any PATCH, and two `role == engineer` agents produce an ambiguity error.

- [ ] **Step 2: Run the CLI test and observe failure**

Run `tests/paperclip-workspace-routing.sh`.

Expected: failure at unknown `agent concurrency` command.

- [ ] **Step 3: Implement concurrency show/set/reset in both CLI copies**

Implement strict integer validation `[1,50]`. Read the full live `runtimeConfig` and `metadata`, then construct merge-preserving payloads:

```sh
_new_runtime="$(printf '%s' "$_agent" | jq --argjson n "$_max" '
  (.runtimeConfig // {}) as $r
  | $r * {heartbeat:(($r.heartbeat // {}) * {maxConcurrentRuns:$n})}
')"
_new_metadata="$(printf '%s' "$_agent" | jq '
  (.metadata // {})
')"
```

For `set`, preserve the marker so live value differing from marker reports `operator_override`. For `reset`, write max 4 and set marker 4. PATCH both merged objects, GET the agent list again, and require the persisted max.

`show` emits:

```json
{
  "agentId": "...",
  "name": "Fullstack Engineer",
  "scope": "agent_global",
  "maxConcurrentRuns": 6,
  "managedDefault": 4,
  "source": "operator_override"
}
```

Copy the script byte-for-byte after each edit.

- [ ] **Step 4: Write failing bootstrap assertions**

Extend `tests/audit-bootstrap.sh` to require:

```bash
hasall "Paperclip isolated workspaces are enabled" patches/paperclip/opc-paperclip-bootstrap.sh \
  'enableIsolatedWorkspaces' \
  '/instance/settings/experimental'
hasall "Fullstack concurrency has a managed default" patches/paperclip/opc-paperclip-bootstrap.sh \
  'FULLSTACK_MAX_CONCURRENT_RUNS_DEFAULT=4' \
  'fullstackMaxConcurrentRuns' \
  'maxConcurrentRuns'
```

Add a fixture-driven bootstrap decision table to `tests/paperclip-workspace-routing.sh` by extracting the decision into a pure shell function in the bootstrap script:

```sh
opc_managed_concurrency_action CURRENT MARKER DEFAULT
```

Expected stdout:

```text
20 '' 4  -> apply
4  4  4  -> keep
6  4  4  -> preserve
4  3  4  -> preserve
```

The bootstrap file must support sourcing only the pure helpers under `OPC_PAPERCLIP_BOOTSTRAP_LIB_ONLY=1`; normal execution remains unchanged:

```sh
if [ "${OPC_PAPERCLIP_BOOTSTRAP_LIB_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
```

This hook exposes decision logic, not API behavior or fake production state.

- [ ] **Step 5: Implement bootstrap feature reconciliation**

After authentication is established and before agent reconciliation:

1. GET `/instance/settings/experimental`.
2. If `enableIsolatedWorkspaces` is not true, PATCH only `{enableIsolatedWorkspaces:true}`.
3. GET again and require true.
4. Print `instance isolated workspaces: enabled/current`; never print the response body on failure.

Do not depend on an environment flag; this is a stack invariant.

- [ ] **Step 6: Implement managed concurrency reconciliation**

Set:

```sh
FULLSTACK_MAX_CONCURRENT_RUNS_DEFAULT=4
```

For both a new executor payload and an existing executor PATCH:

- include merged `runtimeConfig.heartbeat.maxConcurrentRuns` only when action is `apply`;
- include merged `metadata.opcManagedDefaults.fullstackMaxConcurrentRuns=4` when first applying or updating an unchanged managed default;
- preserve a live value differing from its marker;
- preserve all unrelated keys;
- verify the response and then GET the live agent again.

A newly created executor must be born with max 4 and marker 4, rather than briefly inheriting 20.

- [ ] **Step 7: Run focused tests**

Run:

```bash
tests/paperclip-workspace-routing.sh
tests/audit-bootstrap.sh
scripts/prepare.sh
```

Expected: all exit 0; decision table and CLI set/reset assertions pass.

- [ ] **Step 8: Commit**

```bash
git add patches/paperclip/opc-paperclip-bootstrap.sh \
  patches/buzz/opc-paperclip patches/hermes/opc-paperclip \
  tests/fixtures/paperclip-workspace-api.py tests/paperclip-workspace-routing.sh \
  tests/audit-bootstrap.sh
git commit -m "feat: manage Paperclip workspace defaults"
```

---

### Task 3: Engineering project registration, policy ownership, and ticket routing

**Files:**
- Modify: `patches/buzz/opc-paperclip`
- Modify: `patches/hermes/opc-paperclip`
- Modify: `tests/fixtures/paperclip-workspace-api.py`
- Modify: `tests/paperclip-workspace-routing.sh`

**Interfaces:**
- Consumes Task 1 repository normalization/API primitives and Task 2 verified engineer lookup.
- Produces:
  - `opc-paperclip engineering-ticket create --repo <repo> --title <title> [--priority <p>] [--status todo|backlog] [--mode <mode>] [--execution-workspace-id <uuid>]`, description on stdin.
  - `opc-paperclip project workspace set (--repo <repo>|--project-id <uuid>) --mode <mode> [--shared-concurrency auto|serialize|allow] [--strategy <strategy>]`.
  - `opc-paperclip project workspace reset (--repo <repo>|--project-id <uuid>) --lane engineering|prototype`.
- Workspace marker: `metadata.opcWorkspaceDefaults = {lane, mode, strategyType}`.
- Default issue payload binds `projectId`, `projectWorkspaceId`, and `executionWorkspaceSettings.mode = inherit`.

- [ ] **Step 1: Extend the fixture with project/workspace/issue writes**

Add handlers:

```text
POST  /api/companies/<companyId>/projects
PATCH /api/projects/<projectId>
PATCH /api/projects/<projectId>/workspaces/<workspaceId>
POST  /api/companies/<companyId>/issues
GET   /api/issues/<issueId>
```

The project POST must accept an optional nested `workspace`, assign deterministic UUIDs, return hydrated `workspaces` and `primaryWorkspace`, and persist `executionWorkspacePolicy`. Issue POST must default assigned work to `todo`, store exactly the supplied workspace fields, and return an identifier such as `FIX-1`.

- [ ] **Step 2: Write failing engineering routing tests**

Using a fresh fixture state, run:

```bash
printf '%s' 'Acceptance: tests pass' | $CLI engineering-ticket create \
  --repo git@github.com:Owner/Repo.git --title 'Fix race' --priority high \
  >"$TMP/result.json"
```

Assert:

```bash
assert_eq "project auto-created once" "1" \
  "$(jq '[.projects[] | select(.primaryWorkspace.repoUrl == "https://github.com/owner/repo")] | length' "$STATE")"
assert_eq "engineering project default mode" "isolated_workspace" \
  "$(jq -r '.projects[0].executionWorkspacePolicy.defaultMode' "$STATE")"
assert_eq "engineering strategy" "git_worktree" \
  "$(jq -r '.projects[0].executionWorkspacePolicy.workspaceStrategy.type' "$STATE")"
assert_eq "ticket inherits project policy" "inherit" \
  "$(jq -r '.issues[0].executionWorkspaceSettings.mode' "$STATE")"
assert_eq "ticket binds primary workspace" \
  "$(jq -r '.projects[0].primaryWorkspace.id' "$STATE")" \
  "$(jq -r '.issues[0].projectWorkspaceId' "$STATE")"
```

Route a second ticket using another URL form and assert project count stays one. Seed two projects with the same canonical repo and assert the command fails without increasing issue count.

Test override ownership:

1. first adoption writes the marker;
2. `project workspace set --mode shared_workspace --shared-concurrency serialize --strategy project_primary` changes live policy but leaves the last-applied marker;
3. a later engineering ticket preserves the override and sends `mode: inherit`;
4. `project workspace reset --lane engineering` restores isolated/worktree.

Test one-ticket `--mode shared_workspace` writes that mode only on the issue and leaves project policy isolated. Test `reuse_existing` without `--execution-workspace-id` fails before POST.

- [ ] **Step 3: Run tests and observe unknown-command failures**

Run `tests/paperclip-workspace-routing.sh`.

Expected: failure at `engineering-ticket create` or `project workspace set`.

- [ ] **Step 4: Implement project registration and race detection**

Implement this exact order:

1. normalize repo;
2. list projects and collect canonical matches;
3. on zero matches, POST project plus primary `git_repo` workspace and initial isolated/worktree policy;
4. read the returned primary workspace ID;
5. PATCH policy with `defaultProjectWorkspaceId`;
6. PATCH workspace metadata marker, preserving other metadata;
7. list again and require exactly one canonical match;
8. on multiple matches, print project IDs/names and exit nonzero without deleting anything.

The creation payload shape is:

```json
{
  "name": "owner/repo",
  "description": "GitHub engineering project for owner/repo.",
  "status": "in_progress",
  "executionWorkspacePolicy": {
    "enabled": true,
    "defaultMode": "isolated_workspace",
    "workspaceStrategy": {"type": "git_worktree"}
  },
  "workspace": {
    "name": "primary",
    "sourceType": "git_repo",
    "repoUrl": "https://github.com/owner/repo",
    "isPrimary": true
  }
}
```

- [ ] **Step 5: Implement managed project set/reset semantics**

Compare only owned fields against the marker. First adoption of an unmarked engineering Git project applies the default and writes the marker. A live policy differing from a present marker is an override and ticket routing preserves it.

`set` must validate:

```text
shared_workspace -> project_primary unless explicitly compatible
isolated_workspace -> git_worktree by default
operator_branch -> git_worktree by default
adapter_default -> adapter_managed by default
reuse_existing -> not a project default
```

Merge the selected fields into the full live policy. Preserve `branchPolicy`, `pullRequestPolicy`, `runtimePolicy`, `cleanupPolicy`, `authorizationPolicy`, `workspaceRuntime`, and unknown strategy keys such as `baseRef` and `branchTemplate`.

- [ ] **Step 6: Implement verified issue creation**

Read the complete description from stdin. Resolve exactly one active/non-terminated `role == engineer` agent. POST the issue with title, description, priority, status when explicitly supplied, assignee, project, primary workspace, and effective issue settings. Accept only `todo` or `backlog`; omit status by default so Paperclip applies its assigned-ticket `todo` default. The live gate uses explicit `backlog` to prevent an LLM wake.

Default:

```json
{"executionWorkspaceSettings":{"mode":"inherit"}}
```

Explicit one-ticket mode: write only the requested compatible settings. After POST, GET `/issues/<id>` and require the expected assignee/project/workspace/mode. Emit a compact result containing `id`, `identifier`, `projectId`, `projectWorkspaceId`, `mode`, and board URL when `PAPERCLIP_PUBLIC_URL` is available.

- [ ] **Step 7: Run deterministic tests**

Run:

```bash
tests/paperclip-workspace-routing.sh
scripts/prepare.sh
```

Expected: all fixture routing, ambiguity, override, reset, and one-ticket override cases pass; duplicate copies remain identical.

- [ ] **Step 8: Commit**

```bash
git add patches/buzz/opc-paperclip patches/hermes/opc-paperclip \
  tests/fixtures/paperclip-workspace-api.py tests/paperclip-workspace-routing.sh
git commit -m "feat: route engineering tickets to worktrees"
```

---

### Task 4: Prototype project serialization and duplicate first-ticket guard

**Files:**
- Modify: `patches/paperclip/prototype/prototype:85-103,176-267`
- Modify: `patches/buzz/opc-paperclip`
- Modify: `patches/hermes/opc-paperclip`
- Modify: `tests/fixtures/paperclip-workspace-api.py`
- Modify: `tests/paperclip-workspace-routing.sh`
- Modify: `tests/prototype-template.sh`

**Interfaces:**
- Consumes Task 3 project workspace show/set/reset primitives.
- Produces `opc-paperclip prototype-ticket create --name <name> --title <title> [--priority <p>]`, description on stdin.
- Prototype marker: `metadata.opcWorkspaceDefaults = {lane:"prototype", mode:"shared_workspace", strategyType:"project_primary", sharedWorkspaceConcurrency:"serialize"}`.
- `prototype create <name>` guarantees policy reconciliation after project/workspace existence and before linking the current ticket.

- [ ] **Step 1: Write failing prototype helper tests**

Seed no project and no issue, then create a prototype ticket whose stdin begins exactly:

```text
Prototype: recipe-bot
Lane: prototype
Acceptance: preview URL is posted
```

Assert the issue is created without `projectId`. Run the same command again and assert it returns the existing non-terminal issue ID and issue count remains one.

Seed a project named `recipe-bot` with primary local workspace `/prototypes/recipe-bot`, then assert the next helper call includes its `projectId`. Seed two exact-name projects and assert ambiguity fails without creating an issue. A near-miss `recipe-bot-2` must not match.

- [ ] **Step 2: Write failing prototype policy tests**

Extend `tests/prototype-template.sh` after `prototype create` to fetch the created project and assert:

```bash
[ "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.defaultMode')" = shared_workspace ]
[ "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.sharedWorkspaceConcurrency')" = serialize ]
[ "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.workspaceStrategy.type')" = project_primary ]
[ "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.defaultProjectWorkspaceId')" = "$workspace_id" ]
```

PATCH a test-owned project to an operator override, rerun `prototype create`, and assert the override survives. Invoke the reset path through `opc-paperclip project workspace reset --project-id <id> --lane prototype` and assert shared/serialize/project-primary is restored.

- [ ] **Step 3: Run focused tests and observe failure**

Run:

```bash
tests/paperclip-workspace-routing.sh
tests/prototype-template.sh nextjs
```

Expected: helper test fails on unknown `prototype-ticket`; template gate fails because prototype policy is absent. The template test may be deferred until the affected paperclip image is rebuilt, but the deterministic helper test must fail now.

- [ ] **Step 4: Implement prototype-ticket routing**

Validate `^[a-z][a-z0-9-]{1,40}$`. List exact project-name matches:

- one: create continuation ticket with `projectId`;
- zero: search non-terminal issues for an exact first-line `Prototype: <name>` marker; return the existing issue when found, otherwise create without project;
- multiple: fail and list IDs.

Require the input description itself to start with the exact marker. Resolve exactly one agent named `Prototyper`. Preserve existing Buzz marker/watcher steps outside the helper by returning the created/existing issue JSON to the skill.

- [ ] **Step 5: Implement prototype policy reconciliation in the CLI**

Add `project workspace reset --lane prototype` using:

```json
{
  "enabled": true,
  "defaultMode": "shared_workspace",
  "sharedWorkspaceConcurrency": "serialize",
  "defaultProjectWorkspaceId": "<primary-id>",
  "workspaceStrategy": {"type": "project_primary"}
}
```

Use the same marker comparison as engineering. Preserve explicit overrides after the first marker is present.

- [ ] **Step 6: Implement prototype CLI reconciliation**

In `patches/paperclip/prototype/prototype`, add `reconcile_workspace_policy PROJECT_ID` after the create/find block and before current-ticket linking. It must:

1. fetch the hydrated project and unique primary workspace;
2. read workspace metadata marker and live project policy;
3. first adoption: merge shared/serialize/project-primary/default workspace and write marker;
4. marked default unchanged: verify and keep;
5. live owned fields differ from marker: print `prototype: workspace policy operator override preserved` and do not rewrite;
6. verify every write with GET;
7. fail `prototype create` if a required first-adoption policy cannot be established, because otherwise the command would claim a concurrency guarantee it did not create.

Do not call the Hermes-image `opc-paperclip` binary from the Paperclip image; keep this small project-owner reconciliation local to the existing `prototype` CLI and its API helpers.

- [ ] **Step 7: Rebuild and run prototype behavior**

Run:

```bash
scripts/prepare.sh
docker compose up -d --build paperclip
tests/prototype-template.sh nextjs
```

Expected: template lifecycle passes; the test-owned project reports shared mode, serialize concurrency, project-primary strategy, and the same workspace ID across resume.

- [ ] **Step 8: Commit**

```bash
git add patches/paperclip/prototype/prototype \
  patches/buzz/opc-paperclip patches/hermes/opc-paperclip \
  tests/fixtures/paperclip-workspace-api.py tests/paperclip-workspace-routing.sh \
  tests/prototype-template.sh
git commit -m "feat: serialize prototype project workspaces"
```

---

### Task 5: Hermes knowledge, operator workflows, and static ownership checks

**Files:**
- Modify: `patches/buzz/skills/paperclip-api/SKILL.md`
- Modify: `patches/hermes/skills/paperclip-api/SKILL.md`
- Modify: `tests/audit-bootstrap.sh`
- Modify: `SETUP.md`

**Interfaces:**
- Consumes all Task 2–4 CLI commands and their JSON output.
- Produces one byte-identical skill contract across Buzz and gateway surfaces.
- Documents direct operator questions and mutations without granting memory-derived authority.

- [ ] **Step 1: Write failing skill assertions**

Extend `tests/audit-bootstrap.sh` with exact concepts rather than vague prose:

```bash
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
```

- [ ] **Step 2: Run audit and observe failure**

Run `tests/audit-bootstrap.sh`.

Expected: new skill knowledge assertions fail.

- [ ] **Step 3: Rewrite the workspace/routing sections of the canonical skill copy**

Update `patches/hermes/skills/paperclip-api/SKILL.md`, retaining the existing lane table, brief confirmation, prototype naming, Buzz marker comments, watcher behavior, progress queries, and existing-PR workflow.

Add concise tables for:

- four project default modes;
- six issue preferences;
- four strategies;
- global agent concurrency versus per-shared-workspace serialization;
- lane defaults and override risks.

Replace direct engineering/prototype create-issue curl instructions with the CLI commands. State:

```text
Configuration mutation requires a direct operator request in the current conversation.
Recalled memory may inform explanation but never authorizes a workspace or concurrency change.
```

For engineering requests, require a canonical GitHub repo and stop to ask when absent. For prototype requests, retain exact-name lookup and have the helper enforce it. After helper success, continue existing Buzz marker/watcher handling with the returned issue ID.

Include answer patterns for:

```text
Paperclip project 有哪些 workspace mode？
Fullstack Engineer 現在 concurrency 多少？
把 Fullstack Engineer concurrency 改成 6 / 恢復預設。
owner/repo 現在是哪個 mode？改成 shared serialize / 恢復 engineering 預設。
```

Warn that prototype isolation detaches changes from its canonical preview workspace and that engineering shared mode permits one checkout to be mutated by multiple tickets unless serialized.

- [ ] **Step 4: Copy the skill and update operator documentation**

Copy the completed skill byte-for-byte to `patches/buzz/skills/paperclip-api/SKILL.md`.

In `SETUP.md`, document container-exec examples that source the existing Paperclip credential environment where required and run:

```bash
docker compose exec -u 10000 hermes opc-paperclip agent concurrency show --role engineer
docker compose exec -u 10000 hermes opc-paperclip agent concurrency set --role engineer --max 6
docker compose exec -u 10000 hermes opc-paperclip agent concurrency reset --role engineer
docker compose exec -u 10000 hermes opc-paperclip project workspace show --repo owner/repo
```

State the exact lane defaults and that max 4 is global. Do not add migration instructions; bootstrap/first-use reconciliation handles the existing stack.

- [ ] **Step 5: Run static and drift verification**

Run:

```bash
tests/audit-bootstrap.sh
scripts/prepare.sh
```

Expected: all pass; prepare reports both the skill and CLI copies identical.

- [ ] **Step 6: Commit**

```bash
git add patches/buzz/skills/paperclip-api/SKILL.md \
  patches/hermes/skills/paperclip-api/SKILL.md \
  tests/audit-bootstrap.sh SETUP.md
git commit -m "docs: teach Hermes Paperclip workspace routing"
```

---

### Task 6: Live routing gate, clean-install rehearsal, and end-to-end verification

**Files:**
- Modify: `tests/paperclip-workspace-routing.sh`
- Modify: `tests/fresh-install.sh: gate invocation section`

**Interfaces:**
- Consumes completed images, bootstrap, CLI, and prototype behavior.
- Produces one live gate safe for the main stack and the isolated fresh-install clone.
- No new production API.

- [ ] **Step 1: Add live feature/default/override checks**

Extend `tests/paperclip-workspace-routing.sh` with `--fixture` and `--live` modes; no argument runs fixture tests followed by live tests when Docker Compose is available.

For live mode:

1. obtain the board key inside the Paperclip container without printing it;
2. GET `/api/instance/settings/experimental` and require `enableIsolatedWorkspaces == true`;
3. resolve exactly one `role == engineer` and require live max 4 only when its marker indicates managed default;
4. save the complete original agent `runtimeConfig` and `metadata` in a 0600 temporary file;
5. set max 6 through the Hermes CLI;
6. force-recreate `paperclip-bootstrap` and require max remains 6;
7. reset through the CLI and require 4;
8. trap restoration of the original objects even on failure.

The restoration PATCH must use the exact saved objects, not reconstructed subsets.

- [ ] **Step 2: Add test-owned project and ticket checks**

Use a unique repository identity such as:

```text
https://github.com/opc-fixture/workspace-routing-<timestamp>
```

Create a backlog engineering ticket through `engineering-ticket create --status backlog` so no LLM wakes. Assert via API:

- one project and one primary `git_repo` workspace;
- isolated/worktree managed default;
- ticket binds project and primary workspace and uses `inherit`;
- a second URL form reuses the project;
- workspace show reports `source = managed_default`.

Create/resume a test-owned prototype through the actual `prototype` CLI and assert shared/serialize/project-primary. Cleanup only the test-owned issue/project through API and the prototype through its explicit test cleanup path; never call `prototype destroy` on a non-test name.

- [ ] **Step 3: Add execution behavior checks without an LLM**

Create a test-only process adapter agent through Paperclip's API whose command records `PAPERCLIP_WORKSPACE_CWD` and waits on a fixture-controlled file. Assign two engineering issues for the test Git project and assert their reported execution-workspace paths differ and both reside outside the project-primary checkout.

For prototype serialization, create a test process agent bound to the prototype project workspace, start one run that holds the workspace, then assign a second issue. Assert the second wakeup/run is queued or scheduled with `workspace_busy` until the holder exits. Create an issue on a different prototype project and assert it dispatches while the first remains held.

Use bounded waits and dump Paperclip run/wakeup state on failure. Delete the test agent and records in the trap.

- [ ] **Step 4: Run the live gate against rebuilt services**

Run:

```bash
scripts/prepare.sh
docker compose up -d --build frontdoor hermes paperclip
docker compose up --force-recreate paperclip-bootstrap
tests/paperclip-workspace-routing.sh --live
```

Expected: feature, global default, override persistence, reset, engineering project routing, distinct worktrees, prototype persistent workspace, same-project serialization, and different-project concurrency all pass.

- [ ] **Step 5: Add the gate to fresh-install rehearsal**

In `tests/fresh-install.sh`, invoke from the cloned repository with its compose-project environment:

```bash
tests/paperclip-workspace-routing.sh --live
```

Place it after Paperclip bootstrap and connectivity are healthy and before teardown. Ensure the gate inherits the clone's `COMPOSE_PROJECT_NAME`, `IMAGE_PREFIX`, and shifted ports; it must not address the main stack by hard-coded container names or ports.

- [ ] **Step 6: Run existing focused regression gates**

Run:

```bash
tests/audit-bootstrap.sh
tests/connectivity.sh
tests/prototype-template.sh nextjs
```

Expected: all pass. These cover bootstrap ownership, existing service connectivity, and the persistent prototype lifecycle.

- [ ] **Step 7: Run the clean-install proof**

Run:

```bash
tests/fresh-install.sh
```

Expected: the isolated clone completes setup and every included gate, including `paperclip-workspace-routing.sh --live`, exits 0. Do not run `docker compose down -v` against the main project.

- [ ] **Step 8: Review changed surfaces and commit verification wiring**

Confirm only `patches/`, tests, scripts, `SETUP.md`, and approved spec/plan files changed; no `upstream/` source is tracked as modified. Then commit:

```bash
git add tests/paperclip-workspace-routing.sh tests/fresh-install.sh
git commit -m "test: verify Paperclip workspace routing"
```

---

## Final acceptance checklist

- [ ] Fresh install enables isolated-workspace controls without manual UI steps.
- [ ] Fullstack Engineer defaults to four runs globally.
- [ ] A direct concurrency override survives bootstrap; reset returns to four.
- [ ] New and existing engineering GitHub projects default to isolated worktrees without overriding later operator choices.
- [ ] Engineering tickets bind a unique project and primary workspace; ambiguity creates no ticket.
- [ ] One-ticket workspace overrides do not mutate the project default.
- [ ] Prototype create/resume keeps one persistent repository and applies shared/project-primary/serialize defaults.
- [ ] A second run for one prototype serializes; another prototype remains runnable.
- [ ] Hermes can explain modes, strategies, preferences, inheritance, and concurrency scopes.
- [ ] Hermes can show/set/reset concurrency and project mode only on direct operator request.
- [ ] Buzz and Hermes helper/skill copies are drift guarded.
- [ ] `tests/audit-bootstrap.sh`, `tests/connectivity.sh`, `tests/prototype-template.sh nextjs`, `tests/paperclip-workspace-routing.sh --live`, and `tests/fresh-install.sh` pass.
