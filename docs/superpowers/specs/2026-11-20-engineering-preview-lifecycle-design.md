# Engineering preview lifecycle (review-app style)

Status: design, awaiting approval · 2026-11-20 (builder-checked)

## 1. Why

On 2026-11-19 one preview of one change (champi-survivor PR #4) took four
Paperclip tickets: OPC-256 (the code), OPC-257 (build + serve), OPC-258 (stop
the server, release the port lease), OPC-259 (delete the scratch directory).
Each extra ticket woke the Fullstack Engineer for a full LLM run to do a few
seconds of mechanical work, and the preview itself was a `nohup` process that
Paperclip did not know existed.

The commit `6fba663` already said previews should be Paperclip-native runtime
services, but nothing implemented it: champi-survivor has no runtime service
configured, so the only path that worked was the old one (and a stale
runtime-authored skill kept teaching it; that part was fixed in `ed183b9`).

The owner wants something close to a GitLab review app: **the environment
belongs to the ticket that wrote the code**, and opening/closing it is a
sentence in Buzz, not a ticket.

## 2. Goals

1. A preview is a Paperclip runtime service **on the code ticket's own
   execution workspace** (its git worktree). No scratch checkouts, no
   detached processes, no preview-only tickets.
2. Two ways to open one:
   - the ticket's brief asks for it at creation ("做完順便開環境讓我測") — the
     preview is up when the work is handed over;
   - the owner asks later in the ticket's Buzz thread ("開環境").
3. Closing:
   - automatically when the ticket reaches `done` or `cancelled`;
   - manually any time ("關掉環境"), without changing the ticket's status.
4. A ticket that asked for a preview is **not `done` when the code is done**.
   It goes to `in_review`, assigned to the owner, and becomes `done` only when
   the owner accepts ("測試通過").
5. Open/close by request costs no agent run and no LLM call: the front door
   performs it directly through the Paperclip API.
6. Works out of the box on a clean `setup.sh` — no new external dependency.

## 3. Non-goals

- GitHub integration (PR merge/close does not drive anything; the ticket
  status is the lifecycle signal).
- HTTPS / Tailscale-served previews. Paperclip ships a Tailscale broker
  (`packages/tailscale-https-broker`) that would give `https://…ts.net:42xxx`
  URLs; the owner explicitly chose not to make Tailscale a hard dependency.
  Possible later upgrade, out of scope here.
- Changing the prototype lane (`prototype expose`). See §9 for a related
  finding.
- The secret-exposure finding in §9 (tracked separately).

## 4. Anti-goals (these would make it a failure even if it "works")

- A preview that Paperclip does not know about (any `nohup`/`setsid`, any
  process outside a runtime service record).
- A preview that needs its own ticket to open, rebuild, close or clean up.
- A green status with a dead link: a service reported running whose URL is not
  reachable from the owner's browser.
- A ticket marked `done` while the owner has not tested a preview they asked
  for.
- An `in_review` ticket that keeps re-waking the engineer (see §6.3).

## 5. Constraints found in the code (not choices)

- **Agents cannot write runtime service commands.** Paperclip rejects any
  agent key that mutates host-executed workspace commands, including on a
  single execution workspace
  (`server/src/routes/workspace-command-authz.ts`
  `assertNoAgentHostWorkspaceCommandMutation`, used by
  `PATCH /execution-workspaces/:id`). A board key may. The front door holds a
  board key (`/keys/paperclip-api.key`, minted by
  `opc-paperclip-bootstrap.sh` step 4) and so does event-bridge.
- **Paperclip's `port: {type: "auto"}` binds loopback ephemeral ports**, which
  docker does not publish. Only `21000-21015` on the paperclip container are
  published. A preview must therefore listen on an explicit port from that
  range.
- **A running runtime service blocks Paperclip's terminal-workspace reaper**
  for that worktree (`execution-workspaces.ts`, the
  `not exists (… workspaceRuntimeServices … status <> 'stopped')` guard). So
  stopping the service on `done` is what lets Paperclip reclaim the worktree;
  without it the worktree lives forever.
- **`in_review` with only an agent assignee is "stalled"** in Paperclip's review
  liveness (`recovery/issue-graph-liveness.ts` `classifyIssueReviewPaths`) and
  triggers review-path recovery that wakes the agent. Assigning the issue to a
  human user (`assigneeUserId`) is a `human_reviewer` path and is "covered".
- **Reopening a ticket restores an archived worktree**
  (`cleanupTerminalWorkspace` is fenced by a lifecycle generation that a
  reopen bumps; reopen rebuilds the worktree).
- Runtime services inherit the Paperclip server environment minus
  `PAPERCLIP_*` / `DATABASE_URL` / a few auth keys
  (`runtime-service-env.ts`). See §9.

## 6. Design

### 6.1 Where "how to build and serve" lives: the repo

The command Paperclip runs is the same for every engineering project and is
written by OPC, not by agents (constraint above). It only delegates to a
**repo-owned preview entrypoint**:

- Convention: an executable `.paperclip/preview` at the repo root. It must
  build whatever the commit needs and then serve it in the foreground on
  `0.0.0.0:$PORT` (it receives `PORT`, `HOST=0.0.0.0`, and the worktree as
  cwd). Static builds and dev servers are both fine; the script decides.
- The Fullstack Engineer writes this script the first time a repo needs a
  preview, **commits it with the PR**, and the owner reviews it like any other
  code. Later tickets on the same repo reuse it and may change it.
- If the entrypoint is missing, the preview fails to start with an explicit
  message naming the file; it does not guess.

The fixed OPC command (name is the builder's choice, e.g. `opc-preview-run`)
is baked into the paperclip image: it checks the entrypoint exists and is
executable, then `exec`s it. Nothing else.

### 6.2 Who configures and starts it: the front door, through `opc-paperclip`

Add `preview` subcommands to the existing `opc-paperclip` helper (shipped in
both the frontdoor and hermes images, byte-identical copies already enforced
by `scripts/prepare.sh`):

- `opc-paperclip preview up --issue <identifier>`
  1. resolve the issue's current execution workspace
     (`GET /issues/<id>/heartbeat-context` → `currentExecutionWorkspace.id`;
     see the AGENTS.md note that `PAPERCLIP_WORKSPACE_ID` is the *project*
     workspace);
  2. pick a port (§6.4);
  3. `PATCH /execution-workspaces/:id` with a `workspaceRuntime` service:
     the fixed OPC command, explicit `port`, `lifecycle: "shared"`,
     `reuseScope: "execution_workspace"`, HTTP readiness on
     `http://127.0.0.1:{{port}}`, `expose: {type: "url", urlTemplate:
     <public base>:<port>}` (public host derived exactly like
     `DEVENV_HTTP_PUBLIC_HOST`/`PAPERCLIP_PUBLIC_URL` today);
  4. `POST /execution-workspaces/:id/runtime-services/start`;
  5. wait for Paperclip to report it running, then verify from the front door
     with an HTTP request to the public URL; print the URL, served commit SHA
     (worktree `HEAD`), and status. A non-2xx/unreachable result is a failure,
     not a success with a warning (anti-goal: green with a dead link).
  Idempotent: re-running restarts the same service on the same port
  (this is also "rebuild after new commits").
- `opc-paperclip preview down --issue <identifier>` — `runtime-services/stop`.
  Status of the ticket is untouched. Idempotent.
- `opc-paperclip preview status [--issue <identifier>]` — what is running,
  where, since when.

The front door uses these when the owner says 開環境 / 關掉環境 / 重開環境 in
the ticket's thread, resolving the ticket from the thread the same trusted way
`buzz-feedback continue` already does (`53623bf`). The `paperclip-api` skill
documents the phrases → commands mapping and replaces the current
"QA preview for an existing repo or PR" section.

### 6.3 Delivery when the brief asked for a preview

- The brief says so explicitly (the front door writes it when the owner asks
  at creation). The engineer's acceptance criteria then include: the
  `.paperclip/preview` entrypoint exists and works locally in the worktree
  (the engineer may run it in its own run to check, foreground, then stop it).
- At hand-off the engineer sets the issue to `in_review` **and assigns it to
  the owner's user** (so Paperclip sees a human reviewer path and does not
  re-wake the engineer). It does not set `done`.
- event-bridge emits a new event when an issue enters `in_review` (today it
  emits only `done`/`blocked`/`cancelled`, `poller.py`). The front door, woken
  by that event in the original thread, runs `preview up` if the brief asked
  for a preview, and posts the URL + SHA + its own verification, or the
  failure.
- Owner says 測試通過 → front door sets `done` (→ §6.5 stops the preview).
  **`done` means "accepted", not "merged"** (owner's decision): the PR is not
  touched. Merging stays a separate request (the owner says so, as with PR #4,
  or merges on GitHub). Consequence to state in the skill: Paperclip's archive
  gate wants the work delivered and the tree clean, so an accepted-but-unmerged
  worktree may stay compacted rather than archived until the PR lands — that is
  expected, not a leak. A later reopen rebuilds the worktree on the issue's
  branch; if the branch was deleted after merge, `preview up` fails naming the
  missing branch rather than serving something else.
  Owner reports a problem → existing `buzz-feedback continue` path: issue back
  to the engineer; on the next hand-off the cycle repeats and `preview up`
  rebuilds the same worktree.

A ticket that did *not* ask for a preview keeps today's behaviour (engineer
sets `done` when finished).

### 6.3a Rules settled after review (my calls — flag if wrong)

- **"Preview requested" is a label, not prose.** `opc-paperclip labels ensure`
  creates a `preview` label; the front door adds it when the owner asks for a
  preview at creation *or later*. Asking for a preview at any time puts the
  ticket under the acceptance rule: the engineer hands off to `in_review`
  assigned to the owner instead of `done` (the engineer reads the label; the
  front door reads the label on the `in_review` event). This closes the gap of
  a preview opened mid-work being killed when the engineer sets `done`.
- **A preview belongs to the execution workspace's source issue.** Sub-issues
  can inherit a parent's workspace (`issues.ts` `inheritExecutionWorkspaceFromIssueId`).
  `preview up --issue <child>` resolves to that shared workspace; the automatic
  stop fires only when the workspace's `sourceIssueId` issue reaches
  `done`/`cancelled`, never on a child's terminal state.
- **Rework stops the preview.** When an issue leaves `in_review` back to
  `todo`/`in_progress` (owner reported a problem), event-bridge stops its
  preview — it would otherwise serve a half-edited worktree. The next
  hand-off brings it back. `preview up` during `in_progress` is allowed (the
  owner asked) and the reply says it serves work in progress.
- **`down` stays down.** Only `preview up` or an `in_review` hand-off of a
  labelled ticket starts a preview. The builder must verify an agent run on
  the workspace does not restart a stopped service because a
  `workspaceRuntime` config exists; if it does, clear `desiredState`
  on `down`.
- **Rework goes back to the agent that delivered.** `buzz-feedback continue`
  today dies on an issue with no agent assignee and only sets `status:"todo"`
  on `in_review`. It must reassign to the agent of the issue's last
  completed run, then set `todo`. Update `tests/opc-paperclip.sh`
  accordingly.

### 6.4 Ports

- Partition the existing published range. devenv's HTTP pool shrinks to
  `21000-21011` (prototypes, unchanged behaviour); engineering previews own
  `21012-21015` (4 slots; the owner expects 2-3 concurrent). No change to
  docker's published range, so no paperclip recreate is needed for ports.
  (My call; the split point is a single setting.)
- `preview up` picks the lowest port in its slice not held by any non-stopped
  Paperclip runtime service (Paperclip's own records are the registry — OPC
  keeps no separate port table). If none is free, it fails and lists who holds
  them; it never evicts.
- A stopped service keeps its configured port in its config; re-`up` reuses it
  if still free, otherwise picks again.

### 6.5 Closing

- **Automatic:** when event-bridge observes an issue enter `done` or
  `cancelled`, it stops that issue's execution-workspace runtime services
  (board key, `runtime-services/stop`). Deterministic code, no LLM. This also
  unblocks Paperclip's reaper for the worktree.
- **Manual:** `preview down` (§6.2).
- **Late preview on a `done` ticket:** reopen the same ticket (owner's choice
  over filing a new one): the front door moves it back to `in_review` assigned
  to the owner — Paperclip restores the worktree if it was archived — then
  `preview up`. Same close rules afterwards.

### 6.6 Restarts

A paperclip container recreate kills previews (child processes). Paperclip's
`restartDesiredRuntimeServicesOnStartup` (`workspace-runtime.ts`, v2026.1106.0)
restarts `desiredState: running` services on execution workspaces in
`active`/`idle`/`in_review`/`cleanup_failed`, so no OPC restore is needed;
the live gate should cover one recreate.

**Paperclip's automatic HTTPS default must not apply.**
`PAPERCLIP_MANAGED_RUNTIME_HTTPS` defaults to `auto`, which gives eligible
"Paperclip-managed dev runtimes" `tailscale_https` and a loopback bind. Our
service must set its exposure explicitly (`expose: {type: "url", …}`, which
`resolveRuntimeServiceExposure` honours) and the builder verifies the runner
is not classified as a managed dev runtime; otherwise it is the
green-with-dead-link anti-goal.

## 7. What changes, by component

| Component | Change |
|---|---|
| paperclip image | fixed preview runner command; devenv HTTP pool default count 16 → 12 |
| `opc-paperclip` (frontdoor + hermes) | `preview up/down/status` |
| `paperclip-api` skill (both copies) | replace the QA-preview section: phrases → commands, brief wording for "preview requested", in_review hand-off rules |
| Fullstack Engineer guidance (its skill/instructions in the paperclip bootstrap) | `.paperclip/preview` convention; in_review + assign-to-owner hand-off when a preview was requested |
| event-bridge | `in_review` entry event; stop runtime services on `done`/`cancelled` |
| `.env.example` / compose | preview port slice settings |
| tests | offline: `opc-paperclip` payloads + port picking; event-bridge unit gate for the two new behaviours; live: one end-to-end gate (fixture repo with a trivial `.paperclip/preview`, up → URL 200 → issue `done` → service stopped → port free) |
| docs | AGENTS.md (invariants/pitfalls), SETUP.md (owner-facing usage) |

## 8. Left to the builder (verify, then decide)

- Exact `workspaceRuntime` field shapes Paperclip accepts on an execution
  workspace (mirror what `prototype expose` sends to a project workspace) and
  whether `port` there is honoured as fixed for `isolated_workspace` mode
  (watch `allowFixedPortFallback`: a fallback to an auto port would be the
  "green with a dead link" anti-goal — detect and fail instead).
- Whether Paperclip's startup recovery restarts execution-workspace services.
- How event-bridge maps an issue to its execution workspace(s) for the stop.
- The owner's Paperclip user id for `assigneeUserId` (bootstrap knows the
  board user; expose it the way other bootstrap outputs are exposed).
- Names of the runner and of event types.

## 9. Findings recorded here, handled elsewhere

- **Server secrets are readable by every agent run** (same uid `node`;
  `/proc/<server>/environ` exposes `BETTER_AUTH_SECRET`, `DEVENV_SECRET_SALT`,
  devenv admin passwords, `GITHUB_TOKEN`, LLM keys). Pre-existing; separate
  hardening item agreed with the owner. This design does not make it worse:
  the preview runs repo code that the agent could already run in its own run.
- **`prototype expose` from an agent run is probably broken** on
  v2026.1106.0: the CLI uses the run's agent key when `PAPERCLIP_API_KEY` is
  set, and the endpoint now rejects agent keys writing commands. Unverified;
  check and fix separately.
