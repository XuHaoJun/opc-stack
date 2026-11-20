# Engineering Preview Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A preview of a code ticket is a Paperclip runtime service on that ticket's execution workspace, opened/closed by the front door through `opc-paperclip preview …`, published on an OPC port, and stopped automatically by event-bridge when the ticket is accepted, cancelled, or sent back for rework.

**Architecture:** Paperclip owns the process (start/stop/restart recovery/URL record). OPC supplies (1) a fixed runner command that execs the repo's `.paperclip/preview`, (2) an explicit published port from a dedicated slice, (3) the board-key caller (`opc-paperclip`, front door) and (4) the lifecycle hooks (event-bridge `in_review` event + stop sweep). No OPC port table: Paperclip's runtime-service records are the registry.

**Tech Stack:** POSIX sh + jq + curl (`opc-paperclip`, runner), Python 3 stdlib (event-bridge), docker compose, Paperclip v2026.1106.0 REST API.

**Spec:** `docs/superpowers/specs/2026-11-20-engineering-preview-lifecycle-design.md`

## Global Constraints

- Agents never write runtime-service commands; only board-key callers do (`assertNoAgentHostWorkspaceCommandMutation`).
- No `nohup`/`setsid`/background processes anywhere in the preview path; the repo entrypoint runs in the foreground.
- Preview ports: `21012-21015` (`OPC_PREVIEW_PORT_BASE=21012`, `OPC_PREVIEW_PORT_END=21015`); devenv HTTP pool becomes `21000-21011` (`DEVENV_HTTP_PORT_COUNT=12`, `DEVENV_HTTP_PORT_RANGE_END=21011`). Total published range unchanged.
- Public URL host: `DEVENV_HTTP_PUBLIC_HOST` if set, else the host of `PAPERCLIP_PUBLIC_URL` (same rule as `patches/paperclip/devenv/providers/http.sh`). URL form `http://<host>:<port>`.
- Runtime service name is exactly `preview`; OPC only ever starts/stops services with that name.
- Service config: `lifecycle:"shared"`, `reuseScope:"execution_workspace"`, explicit `port`, readiness `http://127.0.0.1:{{port}}`, `expose:{type:"url", urlTemplate:"http://<host>:{{port}}"}` (explicit exposure so Paperclip's `tailscale_https` default never applies).
- Label `preview` marks "owner asked for a preview"; such tickets hand off as `in_review` assigned to the issue's `createdByUserId`, never `done`.
- `done` means accepted, not merged; nothing in this plan touches GitHub.
- The two `opc-paperclip` copies and the two `paperclip-api` SKILL.md copies stay byte-identical (`scripts/prepare.sh` enforces).
- Exit codes follow `opc-paperclip`: 2 usage, 3 refused/unverified, 4 Paperclip/IO failure; new: 5 = no free preview port.

## Review Focus

1. **Paperclip falls back to an auto port when the fixed port is busy** (`allowFixedPortFallback` for isolated workspaces) — `preview up` must fail, not print a URL that points at the wrong port. Test in Task 2.
2. **Issue has no execution workspace** (never ran, or archived after `done`) — `preview up` fails with a message telling the front door to reopen the ticket. Test in Task 2.
3. **All preview ports held** — fails with exit 5 naming the holding issues; never evicts another preview. Test in Task 2.
4. **Repo without `.paperclip/preview`** — runner exits with a message naming the file; `preview up` reports the service failure instead of waiting forever. Tests in Task 1 and Task 2.
5. **Other runtime services on the same workspace** — event-bridge stops only services named `preview`. Test in Task 4.

---

### Task 1: Preview runner and port slice (paperclip image + compose)

**Files:**
- Create: `patches/paperclip/opc-preview-run`
- Modify: `patches/paperclip/Dockerfile` (COPY + chmod next to the other `/usr/local/bin` helpers)
- Modify: `docker-compose.yml` (paperclip `ports:` and devenv env at lines ~793-800 and ~852; frontdoor and hermes env)
- Modify: `.env.example` (lines ~282-284 plus the two new keys)
- Test: `tests/preview-runner.sh`

**Interfaces:**
- Produces: `/usr/local/bin/opc-preview-run` in the paperclip image. Contract: cwd = worktree; requires `PORT`; sets `HOST=0.0.0.0` if unset; `exec ./.paperclip/preview`. Missing/non-executable entrypoint → stderr `opc-preview-run: no executable .paperclip/preview in <cwd> — this repo has not defined how to serve a preview` and exit 64.
- Produces: env `OPC_PREVIEW_PORT_BASE`, `OPC_PREVIEW_PORT_END`, `DEVENV_HTTP_PUBLIC_HOST`, `PAPERCLIP_PUBLIC_URL` available in **frontdoor** and **hermes** containers (consumed by Task 2).

- [ ] **Step 1: Write the failing test** `tests/preview-runner.sh` (offline, runs inside `${IMAGE_PREFIX:-opc}/paperclip:local` with `--network none --entrypoint sh`):
  - temp dir without `.paperclip/preview` → exit code 64 and stderr contains `.paperclip/preview`;
  - temp dir with an executable `.paperclip/preview` that prints `$HOST:$PORT` and exits 0, run with `PORT=21012` → stdout `0.0.0.0:21012`;
  - structural: `docker compose config --format json` → paperclip published ports cover 21000-21015 exactly once; paperclip env `DEVENV_HTTP_PORT_COUNT=12` and `DEVENV_HTTP_PORT_RANGE_END=21011`; frontdoor and hermes env contain `OPC_PREVIEW_PORT_BASE=21012` and `OPC_PREVIEW_PORT_END=21015`.
- [ ] **Step 2: Run it** — `tests/preview-runner.sh` → FAIL (runner missing).
- [ ] **Step 3: Implement** the runner (≈15 lines, `set -eu`) and Dockerfile COPY. Compose: replace the single devenv `ports:` entry with two entries (devenv `${DEVENV_HTTP_PORT_BASE:-21000}-${DEVENV_HTTP_PORT_RANGE_END:-21011}` and preview `${OPC_PREVIEW_PORT_BASE:-21012}-${OPC_PREVIEW_PORT_END:-21015}`, same `${DEVENV_HTTP_BIND:-0.0.0.0}`); change devenv defaults to 12/21011; pass the four preview env vars to frontdoor and hermes. `.env.example`: document the split in the existing devenv HTTP block.
- [ ] **Step 4: Rebuild + rerun** — `scripts/prepare.sh && docker compose build paperclip && tests/preview-runner.sh` → PASS. `docker compose exec paperclip devenv list` still shows the existing leases (all ≤ 21003).
- [ ] **Step 5: Commit** — `feat(paperclip): add preview runner and a dedicated preview port slice`.

---

### Task 2: `opc-paperclip preview up|down|status` and the `preview` label

**Files:**
- Modify: `patches/buzz/opc-paperclip` (then `cp` to `patches/hermes/opc-paperclip`)
- Test: `tests/opc-paperclip.sh` (extend; same source-only + stubbed `api_request` pattern already used for `buzz-feedback`)

**Interfaces:**
- Consumes: Task 1 env vars; Paperclip endpoints `GET /issues/:id`, `GET /execution-workspaces/:id`, `GET /companies/:c/execution-workspaces` (non-summary; each item carries `runtimeServices[]` with `serviceName`, `status`, `port`, `url`), `PATCH /execution-workspaces/:id` body `{config:{workspaceRuntime:{services:[…]}, desiredState}}`, `POST /execution-workspaces/:id/runtime-services/start|stop` body `{}`, `GET|POST /companies/:c/labels`, `PATCH /issues/:id {labelIds}`.
- Produces (pure, source-only testable):
  - `preview_public_base` → stdout `http://<host>`; die 4 if neither host var yields a host.
  - `preview_service_json <port> <public_base>` → the single service object (Global Constraints values; `command:"opc-preview-run"`, `cwd:"."`).
  - `preview_pick_port <preferred-or-empty> <held-ports-json-array>` → lowest free port in `[OPC_PREVIEW_PORT_BASE, OPC_PREVIEW_PORT_END]`, preferring `<preferred>` when free; exit 5 when none.
  - `ensure_preview_label` → label id of `preview` (create if missing; colour `#0891b2`), reusing the lookup shape of `ensure_ticket_labels_json`.
- Produces (commands, JSON on stdout):
  - `preview up --issue OPC-N` → `{"identifier","url","port","workspaceId","status":"running"}`; adds the `preview` label to the issue.
  - `preview down --issue OPC-N` → `{"identifier","status":"stopped"}`; also PATCHes `desiredState:"stopped"`. Idempotent.
  - `preview status [--issue OPC-N]` → array of `{identifier, port, url, status}` for services named `preview`.
  - `engineering-ticket create … --preview` → ticket created with the `preview` label in `labelIds` (extend `engineering_payload_json` callers, not its signature).

- [ ] **Step 1: Write the failing tests** (append to `tests/opc-paperclip.sh`):
  - `preview_service_json 21012 http://100.92.16.32` → `.name=="preview" and .port==21012 and .reuseScope=="execution_workspace" and .expose.urlTemplate=="http://100.92.16.32:{{port}}" and .command=="opc-preview-run"`.
  - `preview_pick_port "" '[21012,21013]'` → `21014`; `preview_pick_port 21015 '[21012]'` → `21015`; `preview_pick_port "" '[21012,21013,21014,21015]'` → exit 5.
  - `preview_public_base` with `PAPERCLIP_PUBLIC_URL=http://100.92.16.32:3100` → `http://100.92.16.32`; with `DEVENV_HTTP_PUBLIC_HOST=box` → `http://box`.
  - `main preview up --issue OPC-3` against a stubbed `api_request` + stubbed `curl` (as a shell function) where the issue has `executionWorkspaceId:"ws-1"`, the company list holds 21012 on another workspace, and after start the workspace reports `{serviceName:"preview",status:"running",port:21013,url:"http://h:21013"}` → output `.port==21013 and .url=="http://h:21013"`; the recorded PATCH body has `.config.workspaceRuntime.services[0].port==21013` and `.config.desiredState=="running"`.
  - Review Focus 1: same, but the reported running port is `54321` → exit ≠ 0, stderr mentions the port mismatch.
  - Review Focus 2: issue with `executionWorkspaceId:null` → exit 3, stderr contains `reopen`.
  - Review Focus 3: all four ports held → exit 5, stderr names the holding issue identifiers; no PATCH recorded.
  - Review Focus 4: workspace reports the service `failed` → exit 4 and stderr includes the service's last error text; no URL printed.
  - `main preview down --issue OPC-3` → POST `…/runtime-services/stop` recorded and PATCH `desiredState:"stopped"`.
- [ ] **Step 2: Run** — `tests/opc-paperclip.sh` → FAIL on the first new assertion.
- [ ] **Step 3: Implement** the helpers and commands in `patches/buzz/opc-paperclip`; wire `preview` into `main`; add `--preview` to `cmd_engineering_ticket_create`. Start wait: poll `GET /execution-workspaces/:id` every 2 s up to `OPC_PREVIEW_START_TIMEOUT` (default 300 s) for the `preview` service to leave `starting`; then one `curl -fsS -o /dev/null --max-time 10 <url>`; non-2xx → exit 4. Source-issue rule: if the workspace's `sourceIssueId` ≠ the issue, operate on the workspace anyway and report `sourceIssue` in the JSON.
- [ ] **Step 4: Run** — `cp patches/buzz/opc-paperclip patches/hermes/opc-paperclip && tests/opc-paperclip.sh && scripts/prepare.sh` → `opc-paperclip: ok`, `SAME  paperclip CLI (buzz/hermes)`.
- [ ] **Step 5: Commit** — `feat(opc-paperclip): open and close ticket previews through Paperclip runtime services`.

---

### Task 3: Rework goes back to the delivering agent

**Files:**
- Modify: `patches/buzz/opc-paperclip` `buzz_feedback()` (the `in_review` branch and the agent-assignee guard) → copy to hermes
- Test: `tests/opc-paperclip.sh`

**Interfaces:**
- Consumes: `GET /issues/:id/runs` (array, newest first by `createdAt`; each has `agentId`).
- Produces: `in_review` continue → `PATCH /issues/:id {status:"todo", assigneeAgentId:<agent of newest run>, assigneeUserId:null, comment, commentClientRequestId}`. Other statuses unchanged, including the existing "no agent assignee" refusal for them.

- [ ] **Step 1: Write the failing test** — fixture issue `in_review` with `assigneeUserId:"board-user"`, no `assigneeAgentId`; stub `GET /issues/$issue_id/runs` → `[{"agentId":"engineer-1","createdAt":"2026-11-20T02:00:00Z"},{"agentId":"other","createdAt":"2026-11-19T00:00:00Z"}]`. Assert the recorded PATCH has `.assigneeAgentId=="engineer-1" and .assigneeUserId==null and .status=="todo"`. Second case: no runs → exit 3, no write.
- [ ] **Step 2: Run** → FAIL (`issue has no agent assignee`).
- [ ] **Step 3: Implement** — move the assignee guard below the status `case` for non-`in_review` statuses; in the `in_review` branch resolve the agent from runs.
- [ ] **Step 4: Run** — copy to hermes, `tests/opc-paperclip.sh` → ok; the existing "confirmed Buzz feedback returns the same in-review issue" case still passes.
- [ ] **Step 5: Commit** — `fix(opc-paperclip): return reviewed work to the agent that delivered it`.

---

### Task 4: event-bridge — `in_review` event and preview stop sweep

**Files:**
- Modify: `patches/event-bridge/opc_bridge/events.py` (`ISSUE_IN_REVIEW = "paperclip.issue.in_review"`, label `待驗收`, `classify_issue`, `terminal_ts` → `updatedAt` for `in_review`)
- Modify: `patches/event-bridge/opc_bridge/paperclip.py` (two client methods)
- Create: `patches/event-bridge/opc_bridge/preview.py`
- Modify: `patches/event-bridge/opc_bridge/poller.py` (call the edge hook on rework transitions) and `main.py` (run the sweep each loop iteration after `poller.tick`)
- Test: `patches/event-bridge/tests/test_events.py`, `patches/event-bridge/tests/test_preview.py` (new), `patches/event-bridge/tests/test_paperclip.py`

**Interfaces:**
- Produces in `paperclip.py`: `Paperclip.execution_workspaces(issue_id: str | None = None) -> list[dict]` (`GET /api/companies/{c}/execution-workspaces[?issueId=]`), `Paperclip.stop_runtime_services(workspace_id: str) -> dict` (`POST /api/execution-workspaces/{id}/runtime-services/stop` `{}`).
- Produces in `preview.py`:
  - `PREVIEW_SERVICE = "preview"`
  - `live_previews(workspaces: list[dict]) -> list[tuple[str, str]]` → `(workspace_id, source_issue_id)` for workspaces with a `preview` service whose status ≠ `stopped`.
  - `sweep(pc, issue_status: Callable[[str], str]) -> list[str]` → stops previews whose source issue is `done`/`cancelled`; returns stopped workspace ids. Level-triggered, so a bridge outage is caught on the next loop.
  - `stop_for_rework(pc, issue_id: str) -> list[str]` → stops previews of that source issue.
- Poller: when `previous.status == "in_review"` and new status in `{"todo","in_progress"}`, call `preview.stop_for_rework`. Failures are logged and do not block event delivery.

- [ ] **Step 1: Write the failing tests**:
  - `test_events`: `classify_issue({"status":"in_progress"}, {"status":"in_review"}) == ISSUE_IN_REVIEW`; two different `updatedAt` values give two different `issue_event_id`s.
  - `test_preview`: stub pc with workspaces `[{id:"w1",sourceIssueId:"i1",runtimeServices:[{serviceName:"preview",status:"running"}]}, {id:"w2",sourceIssueId:"i2",runtimeServices:[{serviceName:"preview",status:"running"}]}, {id:"w3",sourceIssueId:"i1",runtimeServices:[{serviceName:"db",status:"running"}]}]`, statuses `i1:done`, `i2:in_review` → `sweep` returns `["w1"]` and calls stop only for `w1` (Review Focus 5: `w3` untouched). `stop_for_rework(pc,"i2") == ["w2"]`. A stop that raises `PaperclipError` is logged and the sweep continues.
  - `test_paperclip` (FakePaperclip over a socket): the two new methods hit the exact paths/methods above.
- [ ] **Step 2: Run** — `docker compose build event-bridge && tests/event-bridge.sh` → FAIL on the new tests.
- [ ] **Step 3: Implement** the constants, client methods, `preview.py`, poller hook and main-loop call.
- [ ] **Step 4: Run** — rebuild, `tests/event-bridge.sh` → all pass (existing suite included).
- [ ] **Step 5: Commit** — `feat(event-bridge): announce in-review hand-offs and stop previews with their ticket`.

---

### Task 5: Agent guidance — front door skill and Fullstack Engineer prompt

**Files:**
- Modify: `patches/hermes/skills/paperclip-api/SKILL.md` § "QA preview for an existing repo or PR" (replace) → `cp` to `patches/buzz/skills/paperclip-api/SKILL.md`
- Modify: `patches/paperclip/agent-prompts/fullstack-engineer.md`
- Test: `tests/audit-bootstrap.sh`

**Interfaces:**
- Consumes: command names from Task 2, event `paperclip.issue.in_review` from Task 4.

- [ ] **Step 1: Write the failing audit lines** (`has` checks): the skill names `opc-paperclip preview up`, `preview down`, `engineering-ticket create … --preview`, and `paperclip.issue.in_review`; the engineer prompt names `.paperclip/preview`, `in_review`, and `createdByUserId`; and a negative check that the skill no longer contains `devenv provision` inside the QA-preview section.
- [ ] **Step 2: Run** — `tests/audit-bootstrap.sh` → FAIL.
- [ ] **Step 3: Write the guidance.** Skill: phrases → commands (開環境/重開環境 → `preview up`; 關掉環境 → `preview down`; at creation → `--preview`); on a `paperclip.issue.in_review` event for a labelled ticket run `preview up` and post URL + port + own `curl` result; 測試通過 → `PATCH status:"done"` (event-bridge stops the preview); problems → `buzz-feedback continue`; `done` ticket wanting a preview → reopen to `in_review` assigned to the owner, then `preview up`; `done` ≠ merged. Engineer prompt (short section): if the issue has the `preview` label, ensure an executable `.paperclip/preview` that builds the commit and serves in the foreground on `$HOST:$PORT` (may test it in the run, then stop it), commit it with the change, and hand off with `status:"in_review"`, `assigneeUserId:<issue.createdByUserId>`, `assigneeAgentId:null`; never start detached servers or lease ports for previews.
- [ ] **Step 4: Run** — `scripts/prepare.sh && tests/audit-bootstrap.sh` → PASS; rebuild + recreate `frontdoor hermes paperclip` so the skill and prompt reach the running agents (`opc-paperclip-bootstrap.sh` reconciles instructions on boot).
- [ ] **Step 5: Commit** — `docs(agents): route previews through ticket-owned runtime services`.

---

### Task 6: Live end-to-end gate and operator docs

**Files:**
- Create: `tests/engineering-preview.sh`
- Modify: `AGENTS.md` (architecture bullet for previews; ports line; 已知坑 for fallback-port and createdByUserId hand-off), `SETUP.md` (owner usage + one-time `docker compose up -d paperclip` for the port split)

**Interfaces:**
- Consumes: everything above. Reuses the no-LLM test-agent technique of `tests/paperclip-workspace-routing.sh --live` (process adapter that exits 0) to realize an execution workspace without a model call.

- [ ] **Step 1: Write the gate**: fixture git repo whose `.paperclip/preview` is `exec python3 -m http.server "$PORT" --bind "$HOST"` serving `index.html` containing a random marker; create an engineering issue on it assigned to the test agent; wait for its execution workspace; `opc-paperclip preview up` (run inside frontdoor) → URL body contains the marker from the host; `PATCH status:"done"`; within 3 bridge poll intervals the `preview` service is `stopped` and the port is free (`preview_pick_port` would return it); cleanup via terminate (agents with runs cannot be deleted — leave them idle, as the routing test does).
- [ ] **Step 2: Run** — `tests/engineering-preview.sh` → PASS. Also run `tests/connectivity.sh`, `tests/opc-paperclip.sh`, `tests/event-bridge.sh`, `tests/audit-bootstrap.sh`.
- [ ] **Step 3: Recreate check (manual, recorded in the PR)** — start a preview, `docker compose up -d --force-recreate paperclip`, confirm the same URL serves again (Paperclip `restartDesiredRuntimeServicesOnStartup`).
- [ ] **Step 3b: Reopen check (manual, recorded in the PR)** — on the gate's `done` issue after its worktree is archived (or force `PATCH /execution-workspaces/:id {status:"archived"}`), reopen it to `in_review` assigned to the owner and run `preview up`. If Paperclip does not restore the worktree without an agent run, change the skill's late-preview path to reopen through `buzz-feedback continue` semantics (wake the engineer once) and say so in the PR; do not add an OPC restore mechanism.
- [ ] **Step 4: Docs** — AGENTS.md / SETUP.md as listed.
- [ ] **Step 5: Commit** — `test: gate ticket previews end to end`.
