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

| Action | Command |
|---|---|
| Find your company id | `curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" "$PAPERCLIP_API_URL/api/companies"` → `[0].id` (board key; agent keys: `/api/agents/me` → `.companyId`) |
| Create issue | `curl -fsS -X POST -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" -d '{"title":"...","description":"...","priority":"medium","assigneeAgentId":"<executor-agent-id>"}' "$PAPERCLIP_API_URL/api/companies/<companyId>/issues"` |
| Get issue | `curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" "$PAPERCLIP_API_URL/api/issues/<issueId>"` → `.status`, `.title` |
| Add comment | `curl -fsS -X POST -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" -d '{"body":"..."}' "$PAPERCLIP_API_URL/api/issues/<issueId>/comments"` |
| List comments | `curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" "$PAPERCLIP_API_URL/api/issues/<issueId>/comments"` |
| Set status | `curl -fsS -X PATCH -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" -d '{"status":"done"}' "$PAPERCLIP_API_URL/api/issues/<issueId>"` |
| List agents (to resolve a lane) | `curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" "$PAPERCLIP_API_URL/api/companies/<companyId>/agents"` → match by `.name`, take `.id` |

The API key is a board key auto-created by the stack bootstrap (authenticates
as the admin user). Every issue MUST carry an `assigneeAgentId` — Paperclip
does no automatic routing in this stack (no CEO agent, flat org), so an
unassigned ticket is a ticket nobody wakes up for.

## Routing: pick a lane

The lane decides which agent gets the ticket, and therefore which skills and
working style are applied. Resolve the lane to an agent id at call time by
name — never hardcode an id, they change when the stack is rebuilt.

| Lane | Agent name | Use for |
|---|---|---|
| `engineering` | `OMP Engineer` | Real work: features, bug fixes, existing PRs/issues, anything whose output is meant to be kept |
| `prototype` | `Prototyper` | Fast experiments with a live preview URL — "does this feel right", "what would this look like", "can X even work". Built quickly, then **kept for as long as the user wants it**; see the prototype section below |

**Default to `engineering` whenever you are not sure.** The two failure modes
are not symmetric: a prototype request sent to engineering just gets built
more carefully than it needed to be, while a real feature sent to the
prototype lane is built by an agent told to skip tests, error handling and
abstractions.

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

**Before creating any prototype ticket, look the name up:**

```
curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
  "$PAPERCLIP_API_URL/api/companies/<companyId>/projects" | jq -r '.[].name'
```

| Result | What to do |
|---|---|
| A project with that name exists | This is a CONTINUATION. Create the issue with `"projectId":"<that id>"`. The run then gets the existing working tree, database and preview URL. |
| No such project | New prototype. Create the issue **without** `projectId` — the Prototyper runs `prototype create <name>` on its first wake, which makes the directory, the git repo, the lease and the project. |

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
- Always put `Prototype: <name>` on its own line at the top of the
  `description` — it is how the agent knows which prototype to create or
  resume, and it survives even if `projectId` was omitted.
- Never ask the agent to delete anything. Deletion is `prototype destroy`, run
  by the user, never as part of a ticket.

## Workflow: "develop <X>" request

1. **Clarify** the requirements briefly with the user (language, scope, repo name).
2. **Show the brief** (including `Lane:`) and wait for the user to confirm or
   correct it. Do not create the ticket before they answer.
3. **Create the issue** with `assigneeAgentId` set to the agent resolved from
   the confirmed lane, and:
   - `title`: the project name.
   - `description`: requirements + acceptance criteria, verbatim including:
     - `完成後: gh repo create <name> --private --source . --remote origin --push, 把 repo URL 貼回本 ticket comment, 然後將 issue status 改為 done`
     - repo visibility, tech stack, and any user preferences.
4. **Add a channel marker comment** immediately (Buzz only — skip this and
   the watcher step on surfaces that are not Buzz):
   `{"body":"BUZZ_CHANNEL: <channel-uuid>"}` — the uuid of the Buzz channel
   the user asked in (look at the conversation context / nostr channel).
5. **Spawn the watcher** (background, Buzz only): `/usr/local/bin/opc-issue-watcher.sh <issueId> <channel-uuid> &`
6. **Reply to the user** in whatever surface they asked from:
   「已建立 ticket #<id> (lane: <lane>), 開發中, 完成後我會貼 GitHub link。」

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
is always the `engineering` lane: the output goes back onto a real PR. Do NOT treat paperclip as a Buzz member: there is
no Buzz-side assignment. Create a ticket exactly like "develop <X>":

1. Extract `owner/repo` and the PR/issue number from the GitHub URL.
2. Create the issue with:
   - `title`: the task, e.g. `Resolve conflicts on <owner>/<repo>#<n>`.
   - `description`: the PR/issue URL plus the concrete task, and the
     acceptance criteria verbatim — omp must clone the repo, work the existing
     branch/PR (not create a new repo), push the fix back to that PR, paste
     the PR link into the ticket comment, then set status `done`.
3. Assign to the `engineering` lane's agent (`assigneeAgentId`); on Buzz also
   add the `BUZZ_CHANNEL:` marker comment and spawn the watcher; reply to the
   user.

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
