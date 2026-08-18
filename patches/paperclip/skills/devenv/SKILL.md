---
name: devenv
description: Lease isolated development resources (PostgreSQL with pgvector, Valkey, a preview port) inside the OPC stack. Use when a task needs a database, a cache, or an HTTP port that other work must not collide with.
---

# devenv — development resource leases

You have no Docker and no host access. When a task needs a database, a cache,
or a reachable HTTP port, you lease one:

```sh
devenv provision <key> --with postgres,valkey,http
```

It writes standard names into `.env` in the current directory and prints them:

| Variable | What it is |
|---|---|
| `DATABASE_URL` | Your own PostgreSQL database, pgvector already enabled |
| `VALKEY_URL` | Your own Valkey user, isolated to its own db index |
| `DEV_PORT` | A preview port that is published to the user's machine |
| `DEV_URL` | The URL that port is reachable at |
| `HOST` | `0.0.0.0` — see the warning below |

Then read them from `.env` like any application would. **Nothing else in your
code should know devenv exists**; no devenv-specific config, no hardcoded
hostnames, no hardcoded ports.

`--with` is a comma list; take only what you need. `--with http=3` leases three
consecutive ports (`DEV_PORT`, `DEV_PORT_2`, `DEV_PORT_3`).

## Rules

**`provision` is idempotent — run it freely.** Re-running returns the same
database and the same port, so it is safe at the start of every session. It is
how you pick a lease back up, not just how you create one.

**Never hardcode the port.** Read `DEV_PORT`. The number differs per lease and
a hardcoded one will collide with another prototype.

**Do not override `HOST`.** devenv sets `HOST=0.0.0.0` because a dev server
bound to loopback is unreachable from the user's browser — while the health
check, which runs inside this container, still passes. You get a URL that
reports healthy and does not open. If your framework needs a different flag
for the same thing (`--host 0.0.0.0`, `--bind 0.0.0.0`), pass it.

**Never run `devenv release`.** It drops the database. Releasing is the user's
decision, not a tidy-up step.

## Inspecting

`devenv list` shows every lease: owner, database size, ports, idle time. A `!`
next to a port means it was leased but never exposed.

## Failure

| Exit | Meaning |
|---|---|
| 2 | Bad usage — read the message, it names the problem |
| 3 | Pool exhausted — report it to the user; they decide what to release |
| 4 | Backend unreachable — report it, do not retry in a loop |

On exit 3 or 4, say so in a ticket comment and stop. Do not work around it by
using a shared database or a random port.
