---
name: paperclip-api
description: Create and track Paperclip tickets (issues) via the REST API, and deliver GitHub project links back to Buzz. Use when the user asks to develop/build/create software or a project, asks for progress on a ticket, or asks to push work to GitHub.
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
| Find your company id | `curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" "$PAPERCLIP_API_URL/api/agents/me"` → `.companyId` |
| Create issue | `curl -fsS -X POST -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" -d '{"title":"...","description":"...","priority":"medium"}' "$PAPERCLIP_API_URL/api/companies/<companyId>/issues"` |
| Get issue | `curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" "$PAPERCLIP_API_URL/api/issues/<issueId>"` → `.status`, `.title` |
| Add comment | `curl -fsS -X POST -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" -d '{"body":"..."}' "$PAPERCLIP_API_URL/api/issues/<issueId>/comments"` |
| List comments | `curl -fsS -H "Authorization: Bearer $PAPERCLIP_API_KEY" "$PAPERCLIP_API_URL/api/issues/<issueId>/comments"` |
| Set status | `curl -fsS -X PATCH -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" -d '{"status":"done"}' "$PAPERCLIP_API_URL/api/issues/<issueId>"` |

Issue statuses: `backlog | todo | in_progress | in_review | done | blocked | cancelled`.
List issues (for progress checks): `GET /api/companies/<companyId>/issues`.

## Workflow: "develop <X>" request

1. **Clarify** the requirements briefly with the user (language, scope, repo name).
2. **Create the issue** with:
   - `title`: the project name.
   - `description`: requirements + acceptance criteria, verbatim including:
     - `完成後: gh repo create <name> --private --source . --remote origin --push, 把 repo URL 貼回本 ticket comment, 然後將 issue status 改為 done`
     - repo visibility, tech stack, and any user preferences.
3. **Add a channel marker comment** immediately:
   `{"body":"BUZZ_CHANNEL: <channel-uuid>"}` — the uuid of the Buzz channel
   the user asked in (look at the conversation context / nostr channel).
4. **Spawn the watcher** (background): `/usr/local/bin/opc-issue-watcher.sh <issueId> <channel-uuid> &`
5. **Reply to the user** in Buzz: 「已建立 ticket #<id>, 開發中, 完成後我會在這裡貼 GitHub link。」

## Workflow: "progress? / 好了嗎?" query

1. `GET /api/issues/<issueId>` → `.status`.
2. If `done`: read comments, find the `https://github.com/...` URL, reply with it.
3. Otherwise reply with the current status (in_progress / blocked / etc.).

## Notes

- omp does the development and GitHub push; it is not your job to write the code.
- The watcher posts the link automatically when the ticket reaches `done` —
  do not double-post; if you are in a live conversation when it completes,
  you may answer directly.
- The Paperclip API key authenticates as the frontdoor agent; created issues
  are attributed to it.
