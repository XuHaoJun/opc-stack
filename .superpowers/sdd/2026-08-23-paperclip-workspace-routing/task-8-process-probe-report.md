## Task 8: process probe contract correction (2026-08-23)

### Root cause

The live gate configured `OPC_ISSUE_KEY`, `OPC_PROJECT_ID`, `OPC_WORKSPACE_ID`, `OPC_RECORD`, and `OPC_RELEASE` under `adapterConfig.env`. Paperclip canonicalizes configured environment values to binding objects, while the process adapter forwards only string values. The probe therefore did not receive its control values. The command was also configured as a single `sh <script>` string even though the process adapter spawns the configured executable directly.

### Change

`tests/paperclip-workspace-routing.sh` now configures the executable probe script directly and supplies five positional `adapterConfig.args` values for every process agent:

1. agent issue key (`engineering-a`, `engineering-b`, `prototype-a`, `prototype-b`, or `prototype-c`),
2. project ID,
3. project workspace ID,
4. container record path, and
5. container release path.

The child validates those arguments, records key/project/workspace plus its actual `pwd`, then waits for the release file. No custom environment binding is required; all values are non-secret IDs, keys, or container paths. Existing execution-workspace API assertions, `scheduled_retry` checks, holder cleanup, ownership restoration, and failure behavior were left unchanged.

### Verification

- `bash -n tests/paperclip-workspace-routing.sh` — passed.
- `tests/paperclip-workspace-routing.sh --fixture` — 133 pass, 0 fail.
- `tests/paperclip-workspace-routing.sh --live` — process records were produced; engineering runs passed distinct managed Git-worktree routing and same-prototype `scheduled_retry/workspace_busy` checks. The gate still exited nonzero on pre-existing unrelated live blockers: container-side Git worktree verification failed, different-prototype dispatch was not observed, and two prototype execution-workspace records were `cleanup_failed`; cleanup correctly left dependent prototype records in place rather than claiming success or deleting them.

No upstream source was modified.

## Follow-up cleanup and ownership corrections (2026-08-23)

The live gate now verifies managed engineering worktree paths as the container `node` user, avoiding Git's `safe.directory` ownership guard while still requiring `git rev-parse --git-dir` for both paths. Cleanup selection and active-row verification now include only test-owned rows with `strategyType == "git_worktree"`; persistent `project_primary` rows are excluded and remain owned by the explicit test-prototype destroy path.

Follow-up verification:

- `bash -n tests/paperclip-workspace-routing.sh` — passed.
- `tests/paperclip-workspace-routing.sh --fixture` — 133 pass, 0 fail.
- `tests/paperclip-workspace-routing.sh --live` — engineering Git-worktree validation passed; same-prototype `scheduled_retry/workspace_busy` and different-prototype concurrency passed; all selected test-owned git-worktree rows archived; both test prototypes explicitly destroyed. The gate exited nonzero because two prototype issue deletes returned HTTP 500, which remained reported rather than converted to PASS.

## Final cleanup-order correction (2026-08-23)

Cleanup now cancels test issues, archives and verifies only test-owned `git_worktree` execution rows, destroys each test prototype exactly once and verifies project absence, then deletes tracked issues (accepting 404 cascades) and finally deletes or preserves the engineering project. If cancellation, archive, or prototype verification fails, dependent deletion is skipped and the failure remains a blocker.

Final correction verification:

- `bash -n tests/paperclip-workspace-routing.sh` — passed.
- `tests/paperclip-workspace-routing.sh --fixture` — 133 pass, 0 fail.
- `tests/paperclip-workspace-routing.sh --live` — routing, node-owned Git checks, same-project `scheduled_retry/workspace_busy`, different-project concurrency, and git-worktree archival passed. The gate remained nonzero because the two explicit prototype-destroy project-absence verifications failed; issue/project deletion was conservatively skipped.

## Comment-FK cleanup and exact-path verification (2026-08-23)

Cleanup now validates each test issue's comment list, attempts checked comment deletion through the Paperclip comment endpoint using temporary test-agent owner keys, verifies the list is empty, and only then deletes the issue. Temporary keys are revoked after each attempt; test agents are deleted after comment/issue cleanup. Git validation uses each exact path with `git -c safe.directory=<path> -C <path> rev-parse --git-dir` and bounded path/command diagnostics on failure; no global Git configuration is written.

Final verification:

- `bash -n tests/paperclip-workspace-routing.sh` — passed.
- `tests/paperclip-workspace-routing.sh --fixture` — 133 pass, 0 fail.
- `tests/paperclip-workspace-routing.sh --live` — routing, exact-path Git checks, scheduled-retry/workspace-busy, different-prototype concurrency, and git-worktree archival passed. Some automatically generated comments remained undeletable because the API rejected every available test-agent/engineer owner key; the gate reported those failures and conservatively skipped prototype/project deletion. No false PASS was emitted.

## Ephemeral fresh-install cleanup mode (2026-08-23)

The fresh-install clone now invokes the live routing gate with the explicit `OPC_WORKSPACE_ROUTING_EPHEMERAL=1` environment variable. In that mode the gate still releases and drains process holders, restores the exact saved engineer/pre-existing-project state, and removes container/host probe files, but defers all per-record agent/comment/issue/workspace/project/prototype deletion to the enclosing fresh-install volume teardown. The default main-stack live path remains strict and unchanged; skipped cleanup is not counted as a failure in ephemeral mode, while routing assertion failures remain failures.

Verification:

- `bash -n tests/paperclip-workspace-routing.sh && bash -n tests/fresh-install.sh` — passed.
- `tests/paperclip-workspace-routing.sh --fixture` — 133 pass, 0 fail.
