# Paperclip Workspace Routing Design

**Date:** 2026-08-23  
**Status:** Approved design  
**Scope:** Paperclip workspace defaults, deterministic Hermes routing, Fullstack Engineer concurrency, and Prototyper serialization

## 1. Problem

The stack currently creates engineering and prototype tickets with an assignee but does not establish a complete workspace contract.

For engineering work, Paperclip's defaults permit up to 20 concurrent runs and normally select the shared project workspace. On a local environment, `sharedWorkspaceConcurrency: auto` permits concurrent mutations of that checkout. Ten assigned tickets can therefore start ten OMP runs against one Git index, build tree, dependency directory, and working tree.

For prototype work, isolation is the wrong model. A prototype intentionally owns one persistent local Git repository, one devenv lease, and one project-scoped preview runtime. Its working tree and preview URL must survive across tickets and sessions. The missing guarantee is instead per-project serialization: one runner may mutate a given prototype at a time, while different prototypes may run concurrently.

Hermes also lacks enough Paperclip knowledge to configure or explain these choices. Its current `paperclip-api` skill does not describe workspace modes, does not bind engineering tickets to projects, and does not send structured execution-workspace settings. Putting “use a worktree” in ticket prose is too late: Paperclip chooses the workspace before the assigned agent reads the ticket.

## 2. Goals

1. Enable Paperclip execution-workspace controls on every clean install and existing stack.
2. Make isolated Git worktrees the managed default for Fullstack Engineer projects.
3. Make four concurrent runs the Fullstack Engineer's managed, agent-global default.
4. Keep each prototype on its persistent project-primary repository and serialize runners per prototype project.
5. Permit different prototype projects to run concurrently.
6. Preserve explicit operator overrides across bootstrap and future ticket creation.
7. Give Hermes accurate, actionable knowledge of Paperclip workspace modes, strategies, concurrency scopes, live inspection, and mutation commands.
8. Resolve or safely create the correct Paperclip project before creating an engineering ticket.
9. Keep all routing behavior identical across the Buzz front door and Hermes gateway.
10. Fail closed on missing repository identity, ambiguous projects, invalid policy state, or unverified API writes.

## 3. Non-goals

- No change to upstream Paperclip source or its database schema.
- No second work plane or durable registry outside Paperclip.
- No per-project concurrency limiter for isolated engineering workspaces; Paperclip has no native control for it.
- No automatic prototype deletion, workspace cleanup, or lease garbage collection.
- No GitLab, self-hosted Git, or arbitrary local-path auto-registration in the first implementation.
- No automatic merge, pull-request, or branch-delivery policy beyond Paperclip's existing behavior.
- No global Prototyper concurrency limit of one.

## 4. Design principles

### 4.1 Structured control, not prose

Workspace choice is Paperclip control-plane state. Hermes must send `projectId`, `projectWorkspaceId`, and workspace settings through the API. Ticket descriptions remain requirements, not configuration.

### 4.2 Defaults are not enforcement

The stack supplies safe lane defaults, but an explicit operator request may change them. Reconciliation distinguishes an unchanged managed default from an operator override and preserves the latter.

### 4.3 Paperclip remains the durable owner

Projects, workspaces, issue bindings, agent runtime configuration, and execution policies remain Paperclip state. The helper is a deterministic API client, not another registry.

### 4.4 Lane-specific semantics

Turning on the instance feature only makes workspace policies available. It does not make every lane isolated.

| Lane | Project mode | Strategy | Same-project concurrency | Agent-global concurrency |
|---|---|---|---|---|
| Fullstack Engineer | `isolated_workspace` | `git_worktree` | Allowed in separate worktrees | Managed default 4 |
| Prototyper | `shared_workspace` | `project_primary` | `serialize` | Paperclip default; different prototypes may run together |
| Scientist | Unchanged | Unchanged | Unchanged | Unchanged |

## 5. Components

### 5.1 Paperclip bootstrap reconciliation

`patches/paperclip/opc-paperclip-bootstrap.sh` will reconcile two instance/agent defaults.

#### Isolated workspace feature

The bootstrap sets:

```json
{
  "enableIsolatedWorkspaces": true
}
```

through Paperclip's instance experimental-settings API and verifies the value with a subsequent GET. Failure remains a loud bootstrap error because the routing helper cannot honor its contract while Paperclip silently strips workspace fields.

#### Fullstack Engineer concurrency

The managed default is:

```text
runtimeConfig.heartbeat.maxConcurrentRuns = 4
```

This value is per agent across every project. Four tickets from one repository may consume all four slots; it is not four slots per project.

The bootstrap merges runtime configuration rather than replacing it. It records the last applied default in agent metadata:

```json
{
  "opcManagedDefaults": {
    "fullstackMaxConcurrentRuns": 4
  }
}
```

Reconciliation rules:

1. A new Fullstack Engineer receives value 4 and marker 4.
2. An existing unmarked agent at the upstream default 20 receives value 4 and marker 4.
3. If the live value equals the marker, bootstrap may move it when this repository's default changes in a future release.
4. If the live value differs from the marker, it is an operator override and bootstrap preserves it.
5. A reset command explicitly writes the repository default and updates the marker.
6. All unrelated agent metadata and runtime configuration survive the merge.

This lets an operator ask Hermes to set the limit to 2, 6, or 20 without the next `docker compose up` undoing it.

### 5.2 Deterministic Paperclip helper

Both the Buzz and Hermes images will install an identical helper at:

```text
/usr/local/bin/opc-paperclip
```

The source copies live under `patches/buzz/` and `patches/hermes/`. `scripts/prepare.sh` will reject drift between them, matching the existing duplicated-skill and SOUL checks.

The helper is a small shell CLI using the existing `curl` and `jq` runtime. It reads API configuration from the existing environment and credential mirror; it never reads root-only `/keys` as the runtime user.

Commands:

```text
opc-paperclip engineering-ticket create
opc-paperclip prototype-ticket create
opc-paperclip project workspace show
opc-paperclip project workspace set
opc-paperclip project workspace reset
opc-paperclip agent concurrency show
opc-paperclip agent concurrency set
opc-paperclip agent concurrency reset
```

Ticket descriptions are accepted on stdin. This avoids command-line size, quoting, and JSON-escaping failures.

`engineering-ticket create` defaults to the project's effective policy. A direct operator request may supply a one-ticket `--mode` override (`inherit`, `shared_workspace`, `isolated_workspace`, `operator_branch`, or `agent_default`) and the compatible strategy fields. `reuse_existing` is accepted only with an explicit execution-workspace ID. The helper rejects incompatible combinations before writing the ticket.

Every mutating command performs a GET after the write and verifies the observable fields. A 2xx response without the requested persisted state is a failure.

### 5.3 Hermes Paperclip knowledge

Both copies of `skills/paperclip-api/SKILL.md` will remain byte-identical. The skill will:

- route engineering and prototype tickets through `opc-paperclip` rather than model-authored multi-step curl sequences;
- explain all supported project modes, issue preferences, strategies, and concurrency scopes;
- show current live settings using helper inspection commands;
- distinguish managed defaults from operator overrides;
- allow changes only from a direct operator request, never from recalled memory;
- warn about lane-specific consequences before changing a prototype to isolated mode or engineering to a shared checkout;
- stop and ask for a repository or prototype name when identity is missing;
- stop on ambiguous matches rather than guessing;
- preserve the existing engineering/prototype/research lane decision and Buzz watcher behavior.

## 6. Paperclip workspace knowledge model

Hermes must answer questions such as “Paperclip project 有哪些模式？” without source inspection.

### 6.1 Project default modes

| Mode | Meaning |
|---|---|
| `shared_workspace` | Runs use the project-primary workspace. `sharedWorkspaceConcurrency` controls concurrent use. |
| `isolated_workspace` | Paperclip creates an execution workspace, normally a Git worktree, for the ticket/session. |
| `operator_branch` | Execution follows an operator-managed branch workflow rather than the normal automatic isolated path. |
| `adapter_default` | Paperclip does not select a project workspace; the adapter/runtime owns workspace behavior. |

### 6.2 Issue preferences

| Preference | Meaning |
|---|---|
| `inherit` | Use the project policy. |
| `shared_workspace` | Pin this issue to the shared project workspace. |
| `isolated_workspace` | Pin this issue to an isolated execution workspace. |
| `operator_branch` | Pin this issue to operator-branch behavior. |
| `reuse_existing` | Reuse a specified existing execution workspace. |
| `agent_default` | Delegate workspace selection to the adapter. |

### 6.3 Strategies

Strategies are not modes:

- `project_primary`: use the primary project workspace;
- `git_worktree`: create/use a Git worktree;
- `adapter_managed`: let the adapter manage its workspace;
- `cloud_sandbox`: use a configured cloud-sandbox provider.

### 6.4 Concurrency scopes

- `agent.runtimeConfig.heartbeat.maxConcurrentRuns` is agent-global.
- `sharedWorkspaceConcurrency: serialize` is per shared project workspace.
- `sharedWorkspaceConcurrency: allow` permits shared-workspace overlap.
- `sharedWorkspaceConcurrency: auto` serializes some remote environments but permits overlap for local/SSH environments.
- Isolated workspaces do not have a native Paperclip per-project concurrency limit.

## 7. Engineering project resolution

### 7.1 Repository identity

The first implementation accepts GitHub identities in these forms:

```text
https://github.com/owner/repo
https://github.com/owner/repo.git
git@github.com:owner/repo.git
ssh://git@github.com/owner/repo.git
owner/repo
```

They normalize to a lowercase host plus owner/repository identity while preserving the canonical GitHub HTTPS URL for Paperclip:

```text
github.com/owner/repo
https://github.com/owner/repo
```

Project names are display values and never identity keys.

### 7.2 Lookup and auto-registration

The helper lists active company projects and canonicalizes each primary workspace `repoUrl`.

- Exactly one match: reuse it.
- No match: create one project and one primary `git_repo` workspace.
- Multiple matches: fail with every matching project ID/name; create no ticket.
- Missing or unsupported repository identity: fail and ask the operator.

A newly created project has:

```text
status = in_progress
workspace.sourceType = git_repo
workspace.repoUrl = canonical HTTPS URL
workspace.isPrimary = true
```

The create-project API can create the workspace atomically but cannot reference the not-yet-known workspace ID in `defaultProjectWorkspaceId`. The helper therefore:

1. creates project plus primary workspace and the mode/strategy defaults;
2. reads the created primary workspace ID;
3. patches `defaultProjectWorkspaceId`;
4. re-lists by canonical repository identity;
5. requires exactly one match before creating a ticket.

Paperclip has no unique constraint on repository URL. A concurrent registration race cannot be made atomic without upstream/schema changes. The post-create uniqueness check detects the race and refuses to create either routed ticket until the duplicate is resolved; it never automatically deletes a project it did not prove disposable.

### 7.3 Managed project defaults and overrides

The primary workspace metadata records lane and last-applied defaults:

```json
{
  "opcWorkspaceDefaults": {
    "lane": "engineering",
    "mode": "isolated_workspace",
    "strategyType": "git_worktree"
  }
}
```

On first adoption of an unmarked Git repository project for engineering, the helper applies the engineering defaults selected for this stack and writes the marker. This implements the approved one-time convergence of existing engineering projects.

On later routes:

- live policy equal to the marker: keep/reconcile the managed default;
- live policy different from the marker: preserve the operator override;
- explicit `project workspace reset`: restore the lane default and update the marker.

When applying defaults, the helper merges only owned fields and preserves branch templates, base refs, provision/teardown commands, pull-request policy, cleanup policy, runtime policy, authorization policy, and unrelated workspace metadata.

### 7.4 Engineering ticket contract

By default, the created issue binds the project and primary workspace but inherits the verified effective project policy:

```json
{
  "projectId": "<project-id>",
  "projectWorkspaceId": "<primary-workspace-id>",
  "executionWorkspaceSettings": {
    "mode": "inherit"
  },
  "assigneeAgentId": "<unique-role-engineer-id>"
}
```

For a project still on the managed engineering default, inheritance resolves to `isolated_workspace` plus `git_worktree`. For an operator-overridden project, inheritance preserves that override instead of silently restoring isolation.

When the operator explicitly requests a one-ticket override, the helper writes that mode and its compatible strategy into `executionWorkspaceSettings` without changing the project default. This keeps project defaults and issue overrides separate and removes the earlier ambiguity where an explicit isolated payload could undo a project-level override.

The helper resolves exactly one active agent with `role == "engineer"`. Zero or multiple matches are routing errors.

## 8. Prototype routing and serialization

### 8.1 Persistent repository semantics

A prototype continues to use:

```text
/prototypes/<name>
```

as its one durable local Git repository. No ticket-specific worktree is created. The project-scoped preview runtime and stable URL remain unchanged.

### 8.2 Project policy

After `prototype create <name>` has a project and workspace ID, the CLI reconciles the managed prototype defaults:

```json
{
  "enabled": true,
  "defaultMode": "shared_workspace",
  "sharedWorkspaceConcurrency": "serialize",
  "defaultProjectWorkspaceId": "<prototype-workspace-id>",
  "workspaceStrategy": {
    "type": "project_primary"
  }
}
```

The same marker mechanism records `lane: prototype`, last-applied mode, strategy, and shared concurrency in primary-workspace metadata. First adoption converges existing prototype projects; later operator overrides are preserved. The idempotent resume path runs reconciliation, so no migration script is introduced.

Continuation tickets already include `projectId` under the existing skill contract. Paperclip therefore sees the same project workspace and serializes a second run while the first holds it. Different prototype project workspaces do not block one another.

### 8.3 First-ticket race

A new prototype's first ticket predates its Paperclip project, so project-workspace serialization cannot apply yet. Before creating that ticket, the helper checks:

1. exact prototype project-name matches;
2. non-terminal tickets whose description contains the exact first-line marker `Prototype: <name>`.

If a non-terminal matching ticket exists, the helper returns it instead of creating a second one. Once the first run creates and links the project, normal project serialization becomes authoritative.

The helper never creates a near-miss prototype name and never deletes an existing project or ticket.

## 9. Manual operations

Direct operator requests may inspect or change configuration.

Examples:

```text
「Fullstack Engineer 現在 concurrency 多少？」
「把 Fullstack Engineer concurrency 改成 6」
「把 Fullstack Engineer concurrency 恢復預設」
「owner/repo 現在用哪個 workspace mode？」
「把 owner/repo 改成 shared serialize」
「把 owner/repo 恢復 engineering 預設」
```

Mutation flow:

1. resolve a unique target;
2. fetch live state;
3. explain scope and material lane risk;
4. merge-patch only owned/requested fields;
5. fetch and verify persisted state;
6. report the effective value and whether it is a managed default or override.

Changing a prototype away from shared/project-primary receives a warning that its stable preview is attached to the project workspace and isolated changes will not automatically become that preview's canonical working tree. Hermes still executes an explicit operator decision.

## 10. Failure semantics

The helper uses distinct nonzero failures with actionable stderr messages for:

- missing API URL or runtime-readable credential;
- Paperclip unavailable or unauthorized;
- isolated-workspace feature disabled after reconciliation;
- missing/unsupported repository identity;
- zero or multiple engineering agents;
- multiple projects matching one canonical repository;
- prototype-name ambiguity;
- missing primary workspace;
- invalid requested mode/strategy/concurrency;
- write response not matching requested state;
- post-create registration race;
- ticket response missing the requested project/workspace binding.

A failure before ticket creation leaves no ticket. A project created before a later verification failure remains visible for diagnosis; the helper does not destructively roll it back. Retrying is safe because lookup is by canonical identity and writes are merge-based.

Secrets and API responses containing credentials are never printed. The existing root-only `/keys` boundary remains unchanged.

## 11. Files and ownership

Expected implementation surface:

- `patches/paperclip/opc-paperclip-bootstrap.sh`
  - enable feature;
  - apply/preserve Fullstack concurrency default;
  - record managed-default metadata.
- `patches/paperclip/prototype/prototype`
  - reconcile prototype project policy after create/resume.
- `patches/buzz/opc-paperclip`
- `patches/hermes/opc-paperclip`
  - identical deterministic helper.
- `patches/buzz/Dockerfile`
- `patches/hermes/Dockerfile`
  - install helper.
- `patches/buzz/skills/paperclip-api/SKILL.md`
- `patches/hermes/skills/paperclip-api/SKILL.md`
  - identical workspace knowledge and helper workflow.
- `scripts/prepare.sh`
  - reject helper drift in addition to skill drift.
- focused tests under `tests/`
  - static/API contract and live routing behavior.
- `SETUP.md`
  - operator inspection/override commands and workspace defaults.

No file under `upstream/` is edited directly.

## 12. Verification

### 12.1 Deterministic helper contracts

Tests will use a controlled Paperclip API fixture or test-owned Paperclip records to verify:

1. GitHub URL variants normalize to one identity.
2. unique project reuse;
3. zero-match project registration;
4. multiple-match refusal;
5. merge-preserving policy updates;
6. engineering issue binding and effective mode;
7. prototype active-ticket deduplication;
8. show/set/reset commands;
9. response-verification failures;
10. no secret leakage in errors.

### 12.2 Bootstrap contracts

Verification will prove:

1. clean state enables `enableIsolatedWorkspaces`;
2. fresh Fullstack Engineer gets global limit 4;
3. an explicit concurrency override survives another bootstrap run;
4. reset restores 4;
5. unrelated runtime config and metadata survive.

### 12.3 Prototype contracts

`tests/prototype-template.sh` or a focused companion test will prove:

1. a created prototype project uses shared/project-primary mode;
2. shared concurrency is `serialize`;
3. resume keeps the same directory, Git repository, lease, and preview service;
4. a manual project-policy override survives resume;
5. reset restores prototype defaults.

A concurrency-focused integration test will create two test-owned tickets for one project and show that the second wake is queued/deferred while a holder is active. A separate project remains dispatchable.

### 12.4 Engineering workspace smoke

A test-owned Git repository project will receive two issues and verify distinct execution-workspace/worktree paths. It will not assert merely on stored JSON; it will observe the realized workspace path supplied to each run.

### 12.5 Clean-install proof

Because the instance feature and agent default are bootstrap state, final verification includes `tests/fresh-install.sh`. It exercises an isolated compose project beside the live stack and proves the new defaults without destroying live volumes.

## 13. Rollout and existing stack

There is no migration script.

On the existing single-user stack:

1. rebuild/recreate the affected images and one-shots through the normal compose path;
2. bootstrap enables the feature and applies Fullstack default 4 only when no operator override exists;
3. the first routed engineering ticket adopts/converges its Git repository project;
4. the first create/resume of each prototype adopts/converges its prototype project;
5. subsequent explicit overrides survive.

This is both clean-install complete and compatible with the repository rule that one existing deployment is adjusted through idempotent bootstrap/entrypoint behavior rather than a maintained migration framework.

## 14. Acceptance criteria

The design is complete when all of the following are observable:

- Ten engineering tickets cannot start more than four Fullstack runs globally.
- Concurrent engineering tickets for one repository receive distinct Git worktrees by default.
- One prototype always resumes the same Git repository and preview workspace.
- Two runs for the same prototype are serialized, while runs for different prototypes are not serialized by that project lock.
- A direct Hermes request can inspect, set, and reset Fullstack concurrency and project workspace mode.
- Manual settings survive bootstrap and lane reconciliation.
- Hermes can accurately explain Paperclip modes, strategies, inheritance, and concurrency scopes.
- Missing or ambiguous identity prevents ticket creation.
- Buzz and Hermes routing behavior cannot drift silently.
- Clean-install verification proves the feature and defaults without manual steps.
