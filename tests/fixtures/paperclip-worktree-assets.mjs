import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout } from "node:timers/promises";

// Run only in the network-isolated fixture container at the upstream pin.
const server = "/app/server/dist/services";
const { prepareHeartbeatWorkspace } = await import(`${server}/heartbeat/workspace-preparation.js`);
const { createHeartbeatWorkspaceResolver, resolveExecutionWorkspaceReuseRequestForIssue } =
  await import(`${server}/heartbeat/workspaces.js`);
const { environmentService } = await import(`${server}/environments.js`);
const { environmentRunOrchestrator } = await import(`${server}/environment-run-orchestrator.js`);
const { instanceSettingsService } = await import(`${server}/instance-settings.js`);
const { workspaceOperationService } = await import(`${server}/workspace-operations.js`);
const { executionWorkspaceService } = await import(`${server}/execution-workspaces.js`);
const { createDb, agents, companies, heartbeatRuns, projects, projectWorkspaces, issues, workspaceOperations } =
  await import("/app/server/node_modules/@paperclipai/db/src/index.ts");
const { startEmbeddedPostgresTestDatabase } =
  await import("/app/server/dist/__tests__/helpers/embedded-postgres.js");
const { eq } = await import("/app/server/node_modules/drizzle-orm/index.js");
const sha256 = data => createHash("sha256").update(data).digest("hex");
const revision = sha256(JSON.stringify([
  ["d", "Data"], ["f", "Data/reference", sha256("reference\n")],
  ["d", "game"], ["f", "game/template", sha256("template\n")],
]));
const storePath = `/opt/opc-assets/fixture/revisions/${revision}`;
const repo = "/paperclip/asset-fixture-repo";
const companyId = randomUUID(), projectId = randomUUID(), projectWorkspaceId = randomUUID();
const issueId = randomUUID();
const git = (cwd, ...args) => execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
const cli = (cwd, cmd, env = process.env) => spawnSync("worktree-assets", [cmd], { cwd, env, encoding: "utf8" });
mkdirSync(join(repo, "scripts"), { recursive: true });
git(repo, "init", "--initial-branch=main");
git(repo, "config", "user.name", "Asset fixture");
git(repo, "config", "user.email", "asset-fixture@example.invalid");
writeFileSync(join(repo, ".gitignore"), "/assets/\n/.worktree-assets-state/\n");
writeFileSync(join(repo, ".worktree-assets.json"), JSON.stringify({
  version: 1, store: "fixture", revision: `sha256:${revision}`, entries: [
    { target: "Data", source: "Data", mode: "link" }, { target: "game", source: "game", mode: "clone" },
  ],
}));
writeFileSync(join(repo, "scripts/provision-worktree.sh"), readFileSync("/usr/local/share/opc-assets/provision-worktree.sh"));
git(repo, "add", ".");
git(repo, "commit", "-m", "Pin fixture assets");

const postgres = await startEmbeddedPostgresTestDatabase("opc-assets-acceptance-");
try {
  const db = createDb(postgres.connectionString);
  await db.insert(companies).values({ id: companyId, name: "Assets fixture", issuePrefix: "AST" });
  await db.insert(projects).values({ id: projectId, companyId, name: "Asset project", status: "in_progress" });
  await db.insert(projectWorkspaces).values({ id: projectWorkspaceId, companyId, projectId,
    name: "Default source", sourceType: "local_path", cwd: repo, isPrimary: true });
  const [agent] = await db.insert(agents).values({ companyId, name: "Assets fixture", status: "running",
    adapterType: "process" }).returning();
  const newIssue = async (id, number) => {
    const [issue] = await db.insert(issues).values({ id, companyId, projectId, projectWorkspaceId,
      assigneeAgentId: agent.id, identifier: `AST-${number}`, issueNumber: number,
      title: "Local assets", status: "in_progress", priority: "medium" }).returning();
    return issue;
  };
  const service = executionWorkspaceService(db, { workspaceReaperCooldownDays: 0 });
  const settings = instanceSettingsService(db);
  await settings.updateExperimental({ enableIsolatedWorkspaces: true });
  const localEnvironment = await environmentService(db).ensureLocalEnvironment(companyId);
  const resolvedInstanceSettings = await settings.get();
  const envOrchestrator = environmentRunOrchestrator(db);
  const services = { envOrchestrator, executionWorkspacesSvc: service, workspaceOperationsSvc: workspaceOperationService(db),
    ...createHeartbeatWorkspaceResolver(db), appendRunEvent: async () => {} };
  const prepare = async (issue, workspace = null) => {
    const [run] = await db.insert(heartbeatRuns).values({
      companyId, agentId: agent.id, issueId: issue.id, scopeKind: "issue", status: "running", runtimeMode: "legacy",
    }).returning();
    const result = await prepareHeartbeatWorkspace(db, {
      run, agent,
      task: { issueRef: issue, issueId: issue.id, context: { issueId: issue.id, projectId },
        responsibleUserId: null, previousSessionParams: null },
      policy: { trustPreset: { kind: "standard", preset: "standard", boundary: null, sourcePresets: {} },
        isolatedWorkspacesEnabled: true, effectiveExecutionWorkspaceMode: "isolated_workspace",
        requestedExecutionWorkspaceMode: "isolated_workspace", useIsolatedTaskDirectory: false,
        nativeChatWorkspaceScope: null, projectExecutionWorkspacePolicy: null,
        issueExecutionWorkspaceSettings: null, environmentExecutionWorkspaceSettings: null,
        executionPolicy: { executionMode: "any" } },
      environment: { selectedEnvironmentId: localEnvironment.id, localEnvironment,
        selectedEnvironmentForConfig: localEnvironment,
        environmentResolution: { environmentId: localEnvironment.id, source: "default" }, resolvedInstanceSettings },
      config: { mergedConfig: { workspaceStrategy: { type: "git_worktree", baseRef: "main",
        worktreeParentDir: "/paperclip/asset-fixture-worktrees" } }, configSnapshot: null, secretManifest: [] },
      reuse: { requestedShouldReuseExisting: Boolean(workspace), existingExecutionWorkspace: workspace,
        reusableExistingExecutionWorkspace: workspace, workspaceReuseRequest: resolveExecutionWorkspaceReuseRequestForIssue({
          issueExecutionWorkspaceId: issue.executionWorkspaceId, issueExecutionWorkspacePreference: issue.executionWorkspacePreference,
          existingExecutionWorkspaceStatus: workspace?.status ?? null }),
        nativeRecoveryExecutionWorkspaceId: null, persistedNativeExecutionInput: null, isDotRun: false, runOptions: {} },
      services,
      // No adapter is dispatched; the fixture owns the only preparing controller.
      controllerLease: { assertOwned: async () => {} }, nativeRunnerPreparationSpans: [],
    });
    await envOrchestrator.releaseForRun({ heartbeatRunId: run.id, companyId, agentId: agent.id, status: "released" });
    await db.update(heartbeatRuns).set({ status: "succeeded", finishedAt: new Date() }).where(eq(heartbeatRuns.id, run.id));
    assert.equal(result.skipHostProvision, false);
    return result;
  };

  const first = await prepare(await newIssue(issueId, 1));
  assert.equal(first.executionWorkspace.created, true);
  const workspace = first.persistedExecutionWorkspace;
  const workspaceId = workspace.id;
  const cwd = first.executionWorkspace.cwd;
  const target = (...parts) => join(cwd, "assets", ...parts);
  const original = (...parts) => join(storePath, "payload", ...parts);
  const recorded = await db.select().from(workspaceOperations)
    .where(eq(workspaceOperations.issueId, issueId));
  assert.ok(recorded.some(op => op.phase === "workspace_provision" && op.stdoutExcerpt?.includes("missing-revision")));
  assert.equal(existsSync(target()), false);
  assert.equal(existsSync(join(cwd, ".worktree-assets-state")), false);
  const missing = cli(cwd, "status");
  assert.equal(missing.status, 1, missing.stderr);
  assert.match(missing.stdout + missing.stderr, /missing-revision/);
  const disabled = cli(cwd, "init", { ...process.env, WORKTREE_ASSETS_ENABLED: "false" });
  assert.equal(disabled.status, 0, disabled.stderr);
  assert.match(disabled.stdout + disabled.stderr, /disabled/);
  for (const flag of ["PAPERCLIP_GIT_CACHE_EXPIRATION_ENABLED", "PAPERCLIP_GIT_RESTORE_POINTS_ENABLED"]) {
    const refused = cli(cwd, "init", { ...process.env, [flag]: "true" });
    assert.equal(refused.status, 2, refused.stderr);
    assert.ok((refused.stdout + refused.stderr).includes(flag), refused.stderr);
  }
  writeFileSync("/tmp/opc-assets-ready", `sha256:${revision}\n`);
  for (let i = 0; !existsSync("/tmp/opc-assets-imported"); i++) {
    assert.ok(i < 300, "host did not finish import");
    await setTimeout(200);
  }

  const [boundIssue] = await db.select().from(issues).where(eq(issues.id, issueId));
  assert.equal(boundIssue.executionWorkspaceId, workspaceId);
  const second = await prepare(boundIssue, workspace);
  assert.equal(second.persistedExecutionWorkspace.id, workspaceId);
  assert.equal(second.executionWorkspace.cwd, cwd);
  assert.equal(git(cwd, "status", "--porcelain", "--untracked-files=all"), "");
  assert.equal(realpathSync(target("Data")), original("Data"));
  assert.throws(() => writeFileSync(target("Data", "reference"), "denied"), { code: "EROFS" });
  writeFileSync(target("game", "template"), "ticket derivative\n");
  assert.equal(readFileSync(original("game", "template"), "utf8"), "template\n");
  const paused = cli(cwd, "init", { ...process.env, WORKTREE_ASSETS_ENABLED: "false" });
  assert.equal(paused.status, 0, paused.stderr);
  assert.equal(readFileSync(target("game", "template"), "utf8"), "ticket derivative\n");

  const independent = await prepare(await newIssue(randomUUID(), 2));
  assert.notEqual(independent.executionWorkspace.cwd, cwd);
  assert.equal(readFileSync(join(independent.executionWorkspace.cwd, "assets/game/template"), "utf8"), "template\n");

  const withoutReflink = "/dev/shm/opc-assets-no-reflink";
  git(repo, "worktree", "add", "--detach", withoutReflink, "main");
  const strict = cli(withoutReflink, "init");
  assert.equal(strict.status, 3, strict.stderr);
  assert.equal(existsSync(join(withoutReflink, "assets")), false);
  const fallback = cli(withoutReflink, "init", { ...process.env, WORKTREE_ASSETS_ALLOW_FULL_COPY: "1" });
  assert.equal(fallback.status, 0, fallback.stderr);
  assert.equal(readFileSync(join(withoutReflink, "assets/game/template"), "utf8"), "template\n");
  git(repo, "worktree", "remove", withoutReflink);

  await db.update(issues).set({ status: "done", completedAt: new Date() }).where(eq(issues.id, issueId));
  const sweep = await service.sweepTerminalWorkspaces();
  assert.equal(sweep.archived, 1, JSON.stringify(sweep));
  assert.equal(existsSync(cwd), false);
  assert.equal(readFileSync(original("Data", "reference"), "utf8"), "reference\n");
  const reopened = await service.reopenClosedIsolatedExecutionWorkspaceForIssue({
    workspaceId, issue: { id: issueId, companyId, projectId }, actor: { agentId: null, actorType: "user" },
    authorizationActor: { type: "board", source: "local_implicit", isInstanceAdmin: true },
  });
  assert.equal(reopened.ok && reopened.reopened, true, JSON.stringify(reopened));
  assert.equal(readFileSync(target("game", "template"), "utf8"), "template\n");
  assert.equal(realpathSync(target("Data")), original("Data"));
  assert.equal(git(cwd, "status", "--porcelain", "--untracked-files=all"), "");
  console.log("PASS pinned Paperclip create, reuse, reaper and reopen with immutable assets");
} finally {
  await postgres.cleanup();
}
