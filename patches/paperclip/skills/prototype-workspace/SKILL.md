---
name: prototype-workspace
description: Create, resume and serve a named prototype in the OPC stack, with a stable preview URL the user can open. Use for any prototype-lane ticket.
---

# Prototype workspaces

In this stack a prototype is a **named, long-lived thing**, not a scratch file:

```
prototype "recipe-bot"
  = a Paperclip project      (how the user finds it by name)
  + /prototypes/recipe-bot   (its own directory, its own git repo)
  + a devenv lease           (its own database and preview port)
  + a preview URL            (stable — the user bookmarks it)
```

The ticket names it. Look for `Prototype: <name>` at the top of the
description; if it is missing, derive one (`^[a-z][a-z0-9-]{1,40}$`) and say
which you chose in your first comment.

## Every session starts the same way

```sh
prototype create <name>          # idempotent: creates OR picks up the existing one
cd /prototypes/<name>
```

Run it even when you are continuing — it is the resume path, not just the
create path. It reports whether it created the project or found it.

If the directory already has code, you are **continuing an existing
prototype**. Read it before changing it. Do not start over, do not rename, do
not create `<name>-v2` — the user's bookmark and database belong to this one.

## Serving the preview

```sh
prototype expose <name> --command "<your dev server command>" --start
```

Your command must bind the port from `$PORT` (Paperclip injects it) or
`$DEV_PORT` from `.env`, and bind `0.0.0.0`. Examples:

```sh
prototype expose recipe-bot --command "pnpm dev --port \$PORT --host 0.0.0.0" --start
prototype expose recipe-bot --command "python3 -m http.server \$PORT --bind 0.0.0.0" --start
```

Re-running `expose` with a different command updates the service; it does not
add a second one.

**Post `DEV_URL` back to the ticket as a comment — that URL is the
deliverable.** It is what gets relayed to the user; a ticket that closes
without it reads as "done, but nothing to look at". Do not paste the source
code into the ticket or the chat instead: the point of the preview is that the
user can open it, not read it.

The service idle-stops after 7 days. That stops a process; it deletes nothing.
`prototype expose <name> --start` brings the same URL back.

## What this overrides in the `prototype` skill

The vendored `prototype` skill assumes you are prototyping *inside an existing
production codebase*. Here you usually are not, so:

- **Its rule 1** (put the prototype next to the code it is for, mark it as
  throwaway) does not apply to a standalone prototype — the whole directory is
  the prototype. Follow it only when the ticket points you at a real repo.
- **Its rule 3** ("no persistence by default") is relaxed: you have a real
  database from `.env`. Use it when the question involves persistence.
- **Its rule 6** ("commit to a throwaway branch, fold the decision into the
  real code") becomes: commit to the prototype's own git repo, and write the
  conclusion — the question and the verdict — into the ticket. There is no
  main branch to fold anything into.

Its other rules still hold, and the branch choice (LOGIC.md vs UI.md) is
unchanged.

## Never

- **Never delete a prototype**, or any part of one — not the directory, not the
  database, not the lease. Not to clean up, not to start fresh, not because it
  looks abandoned. Deletion is `prototype destroy`, run by the user.
- **Never hardcode the port.** Read `$PORT` / `$DEV_PORT`.
- **Never `gh repo create` / push to GitHub.** A prototype's git is local by
  design. That is the engineering lane's workflow, not this one.
