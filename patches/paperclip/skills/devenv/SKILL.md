---
name: devenv
description: Lease isolated development resources (PostgreSQL with pgvector, Valkey, RabbitMQ, S3 object storage, a preview port) inside the OPC stack. Use when a task needs a database, cache, message broker, S3 bucket, or HTTP port that other work must not collide with.
---

# devenv — development resource leases

You have no Docker and no host access. When a task needs a database, cache,
message broker, object store, or reachable HTTP port, lease one:

```sh
devenv provision <key> --with postgres,valkey,http
devenv provision <key> --with s3
devenv provision <key> --with rabbitmq
devenv provision <key> --with postgres,rabbitmq
devenv provision <key> --with postgres,s3
```

It writes standard names into `.env` in the current directory and prints them:

| Variable | What it is |
|---|---|
| `DATABASE_URL` | Your own PostgreSQL database, pgvector already enabled |
| `VALKEY_URL` | Your own Valkey user, isolated to its own db index |
| `AMQP_URL` | Your own RabbitMQ user and vhost |
| `DEV_PORT` | A preview port that is published to the user's machine |
| `DEV_URL` | The URL that port is reachable at |
| `HOST` | `0.0.0.0` — see the warning below |
| `AWS_ENDPOINT_URL` | S3 endpoint (`http://devenv-s3:9000`) |
| `AWS_ACCESS_KEY_ID` | S3 access key (`devenv-<key>`) |
| `AWS_SECRET_ACCESS_KEY` | S3 secret key (derived) |
| `AWS_REGION` | `us-east-1` |
| `S3_BUCKET` | Your isolated bucket (`devenv-<key>`) |
| `S3_FORCE_PATH_STYLE` | `true` — required for this backend |

Then read them from `.env` like any application would. **Nothing else in your
code should know devenv exists**; no devenv-specific config, no hardcoded
hostnames, no hardcoded ports.

`--with` is a comma list; take only what you need. RabbitMQ is opt-in; default
remains `postgres,valkey`. `--with http=3` leases three consecutive ports
(`DEV_PORT`, `DEV_PORT_2`, `DEV_PORT_3`).

RabbitMQ use:

```sh
devenv provision <key> --with rabbitmq
```

Read `AMQP_URL`; do not reconstruct credentials or hardcode
`devenv-rabbitmq:5672`. Each lease gets one vhost and one user that has no
global management tags and permissions only in that vhost. Vhosts isolate
connections and broker objects, not CPU, memory, disk, or broker failures.
Use the dedicated-container lane below when the task specifically requires its
own RabbitMQ version, plugins, cluster topology, or failure domain.

S3 use:

```sh
devenv provision <key> --with s3
devenv provision <key> --with postgres,s3
```

Read `AWS_ENDPOINT_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_REGION`, `S3_BUCKET`, and `S3_FORCE_PATH_STYLE`. Wire `S3_BUCKET` and
path-style explicitly; not every SDK reads those two names. Presigned URLs are
internal/host-loopback only in this release. Never use buzz-minio.
Exit 4 means the selected backend cannot complete; do not retry-loop or fall back.

S3 wiring: set `S3_BUCKET` as the bucket name and force path-style addressing
(`S3_FORCE_PATH_STYLE=true` or your SDK's `forcePathStyle` / `pathStyle` flag).
Virtual-host style requires `devenv-<key>.devenv-s3` DNS which compose does not
provide, so path-style is mandatory. Presigned URLs generated from these
credentials are only reachable from inside the Docker network or from the
workstation via `127.0.0.1:${DEVENV_S3_PORT:-9002}`; remote-browser reachability
is not promised in this release.

## When devenv is the wrong tool

devenv serves shared, multi-tenant, modern backends. A daemon that refuses to
be multi-tenant, or a version devenv does not run (very old MySQL, pg 9.6),
belongs to the `podenv` lane — load the **podenv** skill; it holds the decision
table. Do not try to force such a daemon into devenv.

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
decision, not a tidy-up step. Never use buzz-minio and never run devenv release as an agent.

## Inspecting

`devenv list` shows every lease: owner, database size, Valkey db, S3 bucket,
RabbitMQ vhost, ports, and idle time. A `!` next to a port means it was leased
but never exposed. Provider identity comes from the control registry;
`devenv list` does not contact S3 or RabbitMQ, so leases stay visible while an
optional backend is down.

## Failure

| Exit | Meaning |
|---|---|
| 2 | Bad usage — read the message, it names the problem |
| 3 | Pool exhausted — report it to the user; they decide what to release |
| 4 | Backend unreachable — report it, do not retry in a loop |

On exit 3 or 4, say so in a ticket comment and stop. Do not work around it by
using a shared database or a random port. Exit 4 means the selected backend
cannot complete; do not retry-loop or fall back.
