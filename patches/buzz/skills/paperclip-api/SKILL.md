---
name: paperclip-api
description: Create and track Paperclip tickets; route work to the right execution lane (engineering vs prototype).
---

# Paperclip REST API — ticket creation & tracking

Paperclip is the work control plane. The flow: create an issue (ticket) with
acceptance criteria → Paperclip's runtime invokes omp to develop → omp pushes
to GitHub and posts the repo link into the ticket → a watcher posts the link
to Buzz automatically. You (the agent) are the orchestrator; Paperclip never
touches Buzz.

## Endpoints

Base: `$PAPERCLIP_API_URL` (in this stack: `http://paperclip:3100`), auth
header `Authorization: Bearer $PAPERCLIP_API_KEY` (both env vars are already
set in this container).

Every ticket you mention to a user must carry its link:
`$PAPERCLIP_PUBLIC_URL/issues/<identifier>` (e.g. `.../issues/OPC-7`). The
identifier alone makes them go hunting for a board they cannot click to.
`PAPERCLIP_PUBLIC_URL` is the browser-reachable address; `PAPERCLIP_API_URL` is
an internal container name and is useless in a chat message.

| Action | Command |
|---|---|
| Find your company id | `curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" "$PAPERCLIP_API_URL/api/companies"` → `[0].id` (board key; agent keys: `/api/agents/me` → `.companyId`) |
| Create engineering ticket | `printf '%s\n' 'ticket description' \| opc-paperclip engineering-ticket create --repo owner/repo --title '...'` (description is stdin) |
| Create prototype ticket | `printf '%s\n%s\n' 'Prototype: recipe-bot' '...' \| opc-paperclip prototype-ticket create --name recipe-bot --title '...'` (description is stdin) |
| Get issue | `curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" "$PAPERCLIP_API_URL/api/issues/<issueId>"` → `.status`, `.title` |
| Add comment | `curl -fsS -X POST -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" -d '{"body":"..."}' "$PAPERCLIP_API_URL/api/issues/<issueId>/comments"` |
| List comments | `curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" "$PAPERCLIP_API_URL/api/issues/<issueId>/comments"` |
| Set status | `curl -fsS -X PATCH -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" -d '{"status":"done"}' "$PAPERCLIP_API_URL/api/issues/<issueId>"` |
| List agents (to resolve a lane) | `curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" "$PAPERCLIP_API_URL/api/companies/<companyId>/agents"` → select engineering by `.role`; select other lanes by `.name`; take `.id` only from one exact match |

The `opc-paperclip` commands are the only ticket-creation path. They resolve
the live company, agent, project, and primary workspace, reject missing or
ambiguous identity, accept descriptions on stdin, and GET-after-write verify
the result. Do not reconstruct their behavior with model-authored curl.

Configuration mutation requires a **direct operator request in the current
conversation**. Recalled memory may inform an explanation but **never
authorizes** a workspace or concurrency change (or a ticket creation). If the
operator has not directly asked for a mutation, answer with inspection or
explanation only.

The API key is a board key auto-created by the stack bootstrap (authenticates
as the admin user). Every issue MUST carry an `assigneeAgentId` — Paperclip
does no automatic routing in this stack (no CEO agent, flat org), so an
unassigned ticket is a ticket nobody wakes up for.

## Workspace and concurrency knowledge

Workspace policy is durable Paperclip state. Explain it from live inspection,
not from memory, and keep modes, issue preferences, and strategies distinct.

### Project default modes

| Mode | Meaning | Default strategy |
|---|---|---|
| `shared_workspace` | Run in the project-primary workspace; its shared concurrency policy controls overlap. | `project_primary` |
| `isolated_workspace` | Give each execution an isolated workspace, normally a Git worktree. | `git_worktree` |
| `operator_branch` | Follow an operator-managed branch workflow rather than the normal automatic isolated path. | `git_worktree` |
| `adapter_default` | Paperclip does not choose a project workspace; the adapter/runtime owns it. | `adapter_managed` |

`reuse_existing` is an issue preference, not a project default: it requires an
explicit existing execution-workspace ID.

### Issue preferences

| Preference | Meaning |
|---|---|
| `inherit` | Use the project's effective policy (the ticket default). |
| `shared_workspace` | Pin this issue to the shared project workspace. |
| `isolated_workspace` | Pin this issue to an isolated execution workspace. |
| `operator_branch` | Pin this issue to operator-branch behavior. |
| `reuse_existing` | Reuse one specified existing execution workspace. |
| `agent_default` | Delegate workspace selection to the adapter. |

### Workspace strategies

Strategies describe how a mode is realized; they are not modes:
`project_primary` uses the primary workspace, `git_worktree` creates or uses a
Git worktree, `adapter_managed` delegates to the adapter, and `cloud_sandbox`
uses a configured cloud-sandbox provider.

### Concurrency scopes

- `agent.runtimeConfig.heartbeat.maxConcurrentRuns` is **agent-global**, not
  per project. The Fullstack Engineer managed default is **4** (the helper
  accepts 1–50); an operator override is reported separately and survives
  bootstrap.
- `sharedWorkspaceConcurrency` is per shared project workspace:
  `serialize` permits one runner at a time, `allow` permits overlap, and
  `auto` depends on the execution environment.
- Isolated workspaces have no native Paperclip per-project concurrency limit;
  separate worktrees may run concurrently while the agent-global limit still
  applies.

### Lane defaults and risks

| Lane | Project default | Strategy | Same-project concurrency | Agent-global |
|---|---|---|---|---|
| Fullstack Engineer (`engineering`) | `isolated_workspace` | `git_worktree` | Separate worktrees may run together | Managed default 4 |
| Prototyper (`prototype`) | `shared_workspace` | `project_primary` | `serialize` per prototype | Paperclip default; different prototypes may run together |
| Scientist (`research`) | Unchanged by this routing | Unchanged | Unchanged | Unchanged |

Inheritance preserves an explicit project operator override; it does not
silently restore a lane default. A project reset explicitly restores the
lane's managed default. Changing engineering to `shared_workspace` can let
multiple tickets mutate one checkout unless it is serialized. Changing a
prototype to isolation detaches changes from its canonical project-primary
workspace, stable preview, and resumed working tree.

### Inspect, change, and reset

Use these exact helper commands after identity is resolved:

```text
opc-paperclip agent concurrency show --role engineer
opc-paperclip agent concurrency set --role engineer --max 6
opc-paperclip agent concurrency reset --role engineer
opc-paperclip project workspace show --repo owner/repo
opc-paperclip project workspace set --repo owner/repo --mode shared_workspace --shared-concurrency serialize
opc-paperclip project workspace reset --repo owner/repo --lane engineering
opc-paperclip project workspace reset --project-id <prototype-project-id> --lane prototype
```

For a project request, canonicalize `owner/repo` and require exactly one
matching Paperclip project with exactly one primary workspace. Missing or
ambiguous repository/project identity stops the operation and asks the
operator; never guess. A prototype request likewise requires its exact
`[a-z][a-z0-9-]{1,40}` name. The prototype-ticket helper enforces exact-name
lookup, continuation, and active-ticket deduplication; if the user says
"that recipe" without a unique name, list prototypes and ask which one.

Prototype projects use local-path primary workspaces, so do not resolve them
with `--repo owner/repo`. Obtain the exact project ID from the Paperclip
project listing (or the project's show response), then use
`--project-id <prototype-project-id>` for prototype inspection/reset. The
engineering repo form remains `--repo owner/repo`.

Answer patterns:

- 「Paperclip project 有哪些 workspace mode？」—give the four project modes,
  their strategies, and the lane defaults/risk summary above.
- 「Fullstack Engineer 現在 concurrency 多少？」—run `agent concurrency
  show`, report `maxConcurrentRuns`, scope `agent-global`, managed default 4,
  and whether `source` is `managed_default` or `operator_override`.
- 「把 Fullstack Engineer concurrency 改成 6 / 恢復預設。」—only after the
  direct request, run `set --max 6` or `reset`, then report the verified JSON.
- 「owner/repo 現在是哪個 mode？改成 shared serialize / 恢復 engineering
  預設。」—show first; on the direct mutation request run `project workspace
  set --mode shared_workspace --shared-concurrency serialize` or `reset
  --lane engineering`, warn about shared-checkout overlap, then report the
  verified policy.

## Routing: pick a lane

The lane decides which agent gets the ticket, and therefore which skills and
working style are applied. Resolve the lane to an agent id from the live agent
records at call time — never hardcode an id, because ids change when the stack
is rebuilt and the engineering agent's name is configurable.

| Lane | Agent selector | Use for |
|---|---|---|
| `engineering` | Exactly one agent with `role == "engineer"` | Durable production work: end-to-end features, bug fixes, existing PRs/issues, and anything whose output is meant to be maintained |
| `prototype` | Exact name `Prototyper` | Build the smallest inspectable named preview artifact — "does this feel right", "what would this look like", "can X even work". Keep it for as long as the user wants it; see the prototype section below |
| `research` | Exact name `Scientist` | 還沒有答案的問題 —— 「這個做得到嗎」「哪個方案比較快」「這個資料長什麼樣」。科學家用可丟棄的實驗蒐證，然後回報判斷與 backlog 建議，**不會**直接產出要留下來的 production code |

Engineering routing MUST produce exactly one `role == "engineer"` match. Zero
or multiple matches is an explicit routing error: do not guess and do not
create the ticket. Prototyper and Scientist remain exact-name selectors.

**Default to `engineering` whenever you are not sure.** The two failure modes
are not symmetric: a prototype request sent to engineering just gets built
more carefully than it needed to be, while a real feature sent to the
prototype lane is built by an agent told to skip tests, error handling and
abstractions.

`research` 與另外兩條的差別是**有沒有答案**：已經知道要做什麼、只是還沒做，那是
`engineering` 或 `prototype`；還不知道該不該做、或不知道怎麼做比較好，那是
`research`。把還沒想清楚的東西送去 engineering，會得到一個很仔細地實作了錯誤方向
的結果。

Prototype does NOT mean disposable. A prototype lives at a stable URL, keeps
its database, and is resumed by name whenever the user comes back to it. It is
deleted only when the user explicitly asks — never as cleanup, never on your
own initiative.

Adding a lane later means adding a row here, not changing any prompt.

### The lane is part of the brief

Before creating the ticket, show the user the brief and let them correct it.
Include the lane as a field, so switching lanes costs them one word:

```
Lane: prototype
Prototype: recipe-bot      <- prototype lane only; see below
Stack: nextjs +ui          <- prototype lane only; see below
Title: ...
Scope: ...
Acceptance: ...
```

This works identically in every surface (Buzz channel, dashboard chat,
Telegram) because it is just text in the conversation — do not depend on any
UI affordance to carry the routing decision.

Issue statuses: `backlog | todo | in_progress | in_review | done | blocked | cancelled`.
List issues (for progress checks): `GET /api/companies/<companyId>/issues`.

## Prototype lane: names, and how to continue an old one

Every prototype has a NAME, and the name is the handle for everything:
a Paperclip project, a working directory with its own git repo, a database,
and a preview URL that does not change. `recipe-bot`, `invoice-ocr`.

Name rules (it is simultaneously a project name, a directory and a database
identifier): `^[a-z][a-z0-9-]{1,40}$`. Derive one from the request and show it
in the brief so the user can rename it in one word.

**Before creating any prototype ticket, require the exact name and let the
helper perform the lookup.** For a direct operator request, put
`Prototype: <name>` on the first stdin line:

```
printf '%s\n' \
  'Prototype: recipe-bot' \
  'Scope: ...' \
  'Acceptance: ...' |
  opc-paperclip prototype-ticket create --name recipe-bot --title '...'
```

The helper matches the exact project name, resumes an existing project with
its project and primary-workspace IDs, or creates a new first ticket with the
name marker. It also rejects ambiguous projects and duplicate active tickets.
Do not use a model-authored curl create sequence or a near-miss name such as
`recipe-bot-2`; that silently forks the directory, database, URL, and bookmark.

Creating and resuming are the same lookup, which is why "just say the name and
keep going" works — and why you must never skip it. Creating a second project
with a near-miss name (`recipe-bot-2`) silently forks the prototype: new
directory, new database, new URL, and the user's bookmark now points at the
old one.

If the user is vague ("改一下那個食譜的"), list the prototypes and ask which —
do not guess. Guessing wrong means editing the wrong prototype.

### Choosing the stack

The prototype lane has a base template and optional layers. Put the choice in
the brief as `Stack:`, so the user can change it in one word.

| | When |
|---|---|
| `nextjs` | Default for anything with a web interface. Next.js + Postgres (raw SQL + migrations) + Valkey, already wired. |
| `+ui` | Add Tailwind 4 + shadcn/ui — only when the point of the prototype involves how it *looks* or a real interface to click through. |
| `+auth` | Add better-auth (email + password, sessions in Postgres) — only when accounts are part of the question. "Who is logged in" is rarely what a prototype is actually testing; a hardcoded user answers most of them. |
| *(none)* | A question that a single script or HTML file answers. Do not reach for a framework to answer "does this algorithm work". |

**Default to the smallest thing that answers the question.** Layers are
additive and can be applied later, so starting without one costs nothing;
starting with one the prototype never needed costs an install, a slower
feedback loop, and a pile of code nobody reads. When in doubt, leave it out
and let the agent add it when the need is real.

### Prototype tickets differ from engineering tickets

- **No `gh repo create`, no GitHub push.** A prototype's git repo is local and
  that is deliberate. Ask instead for: the preview URL posted back as a comment
  and the issue set to `done`.
- **Say it explicitly: set the issue to `done` in the SAME run that finishes
  the work.** Not as tidiness — Paperclip classifies a run that ends with the
  issue still open by pattern-matching the agent's own prose for blocker
  language ("need … access/credentials/login/account/input"). A prototype about
  accounts trips that on ordinary vocabulary, is classified as blocked, and
  gets woken for a whole second run that re-reads everything to finish up.
  Measured on two tickets here: it roughly doubled wall-clock (16min + 15min,
  and 17min + 21min). Setting `done` is checked first and short-circuits the
  whole heuristic.
- Always put `Prototype: <name>` on its own line at the top of the
  `description` — it is how the agent knows which prototype to create or
  resume, and it survives even if `projectId` was omitted.
- Never ask the agent to delete anything. Deletion is `prototype destroy`, run
  by the user, never as part of a ticket.

## Workflow: "develop <X>" request

1. **Clarify** the requirements briefly with the user (language, scope, repo name).
2. **Show the brief** (including `Lane:`) and wait for the user to confirm or
   correct it. Do not create the ticket before they answer.
3. **Create the issue through the lane helper** only after the operator confirms
   the brief. For engineering, require one canonical GitHub `owner/repo`; if
   it is absent or ambiguous, stop and ask rather than guessing:
   ```
   printf '%s\n' 'Lane: engineering' 'Scope: ...' 'Acceptance: ...' |
     opc-paperclip engineering-ticket create --repo owner/repo --title '...'
   ```
   For prototype, use the exact-name command shown above. The helper resolves
   `assigneeAgentId`, binds project/workspace identity, and verifies the result;
   do not write a direct issue-creation curl payload. Engineering descriptions
   must include:
   `完成後: gh repo create <name> --private --source . --remote origin --push, 把 repo URL 貼回本 ticket comment, 然後將 issue status 改為 done`
   plus repo visibility, tech stack, and user preferences.
4. **Add the marker comments** immediately (Buzz only — skip these and the
   watcher step on surfaces that are not Buzz). Two of them, one call each:
   - `{"body":"BUZZ_CHANNEL: <channel-uuid>"}` — the Buzz channel the user
     asked in.
   - `{"body":"BUZZ_EVENT: <event-id>"}` — the id of the message that asked
     for this (the same EVENT_ID you reply to). The watcher posts the result
     as a reply to it, so the answer lands in the thread that asked rather
     than starting a new one. Omit it and the user gets a detached notice with
     nothing tying it to their request.
5. **Spawn the watcher** (background, Buzz only): `/usr/local/bin/opc-issue-watcher.sh <issueId> <channel-uuid> <event-id> &`
6. **Reply to the user** in whatever surface they asked from, WITH the link:
   「已建立 ticket <identifier> (lane: <lane>): $PAPERCLIP_PUBLIC_URL/issues/<identifier>
   開發中, 完成後我會貼結果。」

## Workflow: "progress? / 好了嗎?" query

1. `GET /api/issues/<issueId>` → `.status`.
2. If `done`: read comments and reply with the link the agent posted —
   a `https://github.com/...` URL for engineering, a `http://localhost:<port>`
   preview URL for a prototype.
3. Otherwise reply with the current status (in_progress / blocked / etc.).

"What prototypes do I have?" is answered from the project list (the same
`GET /api/companies/<companyId>/projects` call), not from memory.

## Workflow: "assign <existing PR/issue> to paperclip"

The user points at an EXISTING GitHub PR/issue and wants Paperclip to take it
over — resolve merge conflicts, address review comments, finish the work. This
is always the `engineering` lane: the output goes back onto a real PR. Do NOT
treat Paperclip as a Buzz member: there is no Buzz-side assignment. Create a
ticket exactly like "develop <X>":

1. Extract `owner/repo` and the PR/issue number from the GitHub URL. Missing
   or ambiguous repository identity is a stop-and-ask condition.
2. Create it through the engineering helper, preserving the concrete task and
   acceptance criteria (omp must clone the repo, work the existing branch/PR,
   push the fix back to that PR, paste the PR link into the ticket comment,
   then set status `done`):
   ```
   printf '%s\n' 'Lane: engineering' 'Existing PR/issue: <URL>' |
     opc-paperclip engineering-ticket create --repo owner/repo \
       --title 'Resolve conflicts on owner/repo#<n>'
   ```
3. On Buzz, add the `BUZZ_CHANNEL:` and `BUZZ_EVENT:` marker comments and
   spawn the watcher; reply to the user with the ticket link. The helper's
   returned issue ID is the ID used for those marker and watcher steps.

## Notes

- The assigned agent does the development and GitHub push; it is not your job
  to write the code.
- Agents differ only in the skills they carry, so the lane you choose IS the
  configuration — there is no way to "add prototype mode" to a ticket after
  the fact. Reassigning means the new agent starts from the ticket text alone.
- The watcher is Buzz-specific. On dashboard chat or Telegram there is no
  watcher: poll the issue when the user asks, or tell them you will check back.
- The watcher posts the link automatically when the ticket reaches `done` —
  do not double-post; if you are in a live conversation when it completes,
  you may answer directly.
- The Paperclip API key authenticates as the frontdoor agent; created issues
  are attributed to it.
- **Never delete a prototype, and never file a ticket that deletes one.**
  A prototype is the user's, on the same footing as a real project. If they
  ask you to remove one, tell them the command (`prototype destroy <name>`,
  which lists what it will erase and asks them to type the name) rather than
  arranging it yourself.
