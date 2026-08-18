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

For a NEW prototype, scaffold from a template instead of starting empty:

```sh
prototype templates              # what is available
prototype create <name> --template nextjs
```

The template is not a suggestion to read — it is working, tested wiring for
Postgres (raw SQL + migrations), Valkey, and a preview server that survives
this environment's quirks. Read its `README.md` before changing any of it;
each line called out there cost a debugging session to find. Its `/api/health`
route tells you in one request whether the plumbing or your code is at fault —
keep it.

`--template` only applies to an empty prototype; re-running create never
overwrites existing work.

### Layers: add capability only when the ticket asks for it

```sh
prototype layers                 # what is available
prototype layer add <name> ui    # Tailwind 4 + shadcn/ui
prototype layer add <name> auth  # better-auth (email + password)
```

Each layer's `README.md` (under its directory) shows how to use what it
installed. Read it — `auth` in particular gives you working HTTP endpoints and
no UI, which is deliberate.

Layers are additive and can be applied at any point, including after you have
started building — so **do not apply one speculatively**. A ticket that says
nothing about the interface does not want a component library; the base
template already renders HTML.

The ticket decides. If the brief carries a `Stack:` line, follow it exactly.

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

### The preview is NOT on localhost — configure the dev server for it

`.env` gives you `DEV_HOST` (bare host, no scheme or port). Modern dev servers
refuse requests whose host is not localhost, and the failure looks like a
broken app rather than a config problem: the page loads, then every JS chunk
403s and nothing on it works.

- **Next.js**: `allowedDevOrigins: [process.env.DEV_HOST]` in `next.config`.
  Next 16 rejects any request carrying an `Origin` header from a non-localhost
  host — including a **same-origin** one, so it hits normal use, not just CORS.
- **Vite**: `server.allowedHosts: [process.env.DEV_HOST]`.

Check your framework for an equivalent before declaring the prototype done,
and open the preview URL once yourself. A `curl` of the page is not enough —
it sends no `Origin` header, so it passes while a browser fails.

The service idle-stops after 7 days. That stops a process; it deletes nothing.
`prototype expose <name> --start` brings the same URL back.

## Project-only skills

A ticket may require a specific skill for this prototype and no other:

```sh
prototype skill add <name> --from https://github.com/owner/repo
#   --path DIR   where the skills live in that repo (default: skills)
#   --only a,b   take only these
```

It vendors them into `<project>/.claude/skills/`, pins the commit in a `SOURCE`
file, and commits. omp discovers skills from the working directory, so they
apply to this prototype and nothing else — that is what makes them
project-only. Run it once at setup; re-run only to update.

Read the skills it installs before you start. If the ticket asked for one, it
is part of the brief, not decoration.

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

## Publishing to GitHub

**Do not.** `prototype publish` exists, it uses the operator's own GitHub
credential, and it is theirs to run. "The prototype turned out well, put it on
GitHub" is a decision they make after looking at it — not a step in finishing a
ticket, and not something to offer to do for them mid-run.

The one exception is a ticket that explicitly asks for it. Even then, say in a
comment that you are about to push and where.

A prototype's git repo is local by design. Commit your work there — the history
is what makes it publishable later.

## Never

- **Never delete a prototype**, or any part of one — not the directory, not the
  database, not the lease. Not to clean up, not to start fresh, not because it
  looks abandoned. Deletion is `prototype destroy`, run by the user.
- **Never hardcode the port.** Read `$PORT` / `$DEV_PORT`.
- **Never `gh repo create` / push to GitHub on your own initiative** (see
  above). A prototype's git is local by design; pushing is the engineering
  lane's workflow, or an explicit request.
