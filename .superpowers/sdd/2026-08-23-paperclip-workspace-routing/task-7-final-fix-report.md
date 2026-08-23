# Task 7 final whole-branch fix report

## Scope

Implemented the nine final whole-branch review findings from the SDD ledger in one coordinated patch. No files under `upstream/` were modified.

## Changes

1. **Durable project operator overrides**
   - `project workspace set` now writes `primaryWorkspace.metadata.opcWorkspaceDefaults.source = operatorOverride` while preserving unrelated metadata.
   - Engineering reconciliation recognizes that marker and leaves the operator policy untouched on later ticket creation.
   - Managed adoption/reset writes `source = managedDefault`; live policy divergence from a managed marker remains an operator override and does not rewrite the marker.

2. **Fail-closed existing-project adoption**
   - Existing unmarked engineering projects now perform PATCH + GET verification through `verify_project_policy` before their managed marker is written.
   - Verification requires `enabled:true`, mode, strategy, and primary default workspace. A supplied shared-concurrency value is also verified.

3. **Complete workspace-set verification**
   - `project workspace set` verifies enabled, requested mode, strategy, default workspace, and optional shared concurrency after GET.
   - The policy merge remains field-preserving for unknown policy keys.

4. **Live helper ownership recovery**
   - The live gate now recovers created project/issue ownership after either engineering CLI ticket helper fails, using the canonical repository and unique test marker through the project/issue APIs.
   - If ownership cannot be proven, it reports an explicit `BLOCKER`/unknown-ownership condition rather than silently proceeding.

5. **Pre-existing live-project safety**
   - The live gate snapshots the exact pre-existing project execution policy and primary-workspace metadata into a mode-600 temporary file before routing.
   - Cleanup restores each with PATCH and GET equality checks and never deletes a pre-existing project.

6. **Safe inspection/mutation output**
   - `project workspace show`, `set`, and `reset` now emit compact project/workspace/policy summaries only: IDs, name/status, repo/source/ref/primary status, owned policy fields, and derived source.
   - Arbitrary project/workspace metadata, runtime configuration, and environment-like values are not serialized.
   - Source is derived as `managed_default`, `operator_override`, or `unmanaged`.

7. **Repository parser hardening**
   - Unsupported `http://github.com/...` is rejected. HTTPS (including trailing slash normalization), SSH/scp, and approved short owner/repo forms remain accepted.

8. **Project-bound prototype dedupe**
   - Projectless first-ticket and terminal-retry epochs retain marker/title protection with `allowDuplicate:false`.
   - Continuation tickets bound to an exact known project use `allowDuplicate:true` while retaining exact project/workspace binding and response verification.

9. **Prior behavior retained**
   - Buzz/Hermes CLI copies remain byte-identical and executable.
   - Existing model-profile schema repair, merge preservation, markers/GET checks, prototype shared/serialize policy, and cleanup safety remain covered.

## Focused verification

- `tests/paperclip-workspace-routing.sh --fixture` — **133 pass, 0 fail**.
  - Includes unmarked operator override survival, omitted-policy-field failure, complete set verification, sanitized output, HTTP rejection, and project-bound same-title prototype ticket coverage.
- `tests/audit-bootstrap.sh` — **39 pass, 0 fail**.
- `sh -n patches/hermes/opc-paperclip`
- `sh -n patches/buzz/opc-paperclip`
- `sh -n patches/paperclip/prototype/prototype`
- `python3 -m py_compile tests/fixtures/paperclip-workspace-api.py`
- `git diff --check`

## Live gate

`tests/paperclip-workspace-routing.sh --live` was run without destructive volume teardown. The gate intentionally remains nonzero on the already-known runtime blockers: the process adapter produced no execution-workspace records and the second same-prototype dispatch did not report the expected scheduled retry. Those are reported as failures/blockers, not fabricated passes. Cleanup restored the engineer runtime/metadata and removed the test projects/agents that were disposable; several issue deletes returned the existing Paperclip HTTP 500 behavior and therefore remained explicit cleanup failures in the gate output.
