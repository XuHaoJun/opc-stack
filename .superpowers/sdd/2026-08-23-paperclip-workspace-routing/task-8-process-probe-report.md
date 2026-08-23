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
