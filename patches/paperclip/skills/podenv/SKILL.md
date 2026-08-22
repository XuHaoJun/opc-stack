---
name: podenv
description: Lease a whole containerized daemon (any OCI image, including very old versions) when devenv cannot serve it — a daemon that refuses to be multi-tenant, or a version devenv does not run. Use only after checking devenv first.
---

# podenv — nested container leases

`devenv` is the shared, multi-tenant, modern lane: PostgreSQL 18 with
pgvector, Valkey 9.1, a preview port. `podenv` is the other half — **a whole
container, all yours**, from any image.

## Which one

**Check devenv first, every time.** If devenv can serve it, use devenv: it is
shared, it is already running, and it costs no disk.

| What you need | Use |
|---|---|
| PostgreSQL, any modern version | `devenv provision <key> --with postgres` |
| Redis / Valkey, any modern version | `devenv provision <key> --with valkey` |
| An HTTP port for a dev server | `devenv provision <key> --with http` |
| MySQL / MariaDB, any version | `podenv` |
| Milvus, Qdrant, Elasticsearch, Kafka, … | `podenv` |
| A daemon that cannot be multi-tenant | `podenv` |
| **An old version of something devenv serves** (pg 9.6, redis 5) | `podenv --dedicated "<why>"` |

**devenv 已提供就優先使用。** podenv enforces this: ask it for a `postgres`,
`pgvector`, `valkey` or `redis` image (or a renaming of the same software,
like `postgresql`) and it refuses, and tells you the devenv command. The
check normalises the image reference first — registry/namespace prefix,
`:tag`, `@digest`, and case all stripped before comparing — so a typical
attempt to dodge it by tag or digest still gets caught. The refusal is not
absolute — an OLD version of those families is a real podenv case — but you
must say why with `--dedicated "<reason>"`, and the reason is stored on the
lease and shown in both `podenv list` and `devenv list`. Write a reason a
person can act on ("pg9.6, devenv is pg18, client API is incompatible"), not
"needed for the task".

**The two leases coexist.** Use the SAME key for both and they land in the
same `.env`:

```sh
devenv provision myproj --with postgres          # -> DATABASE_URL
podenv provision myproj --image milvus/milvus:v2.5.0 --port 19530 \
       --as MILVUS_ADDR                          # -> MILVUS_ADDR
```

podenv refuses to write any variable name devenv owns (`DATABASE_URL`,
`VALKEY_URL`, `DEV_PORT`, `DEV_PORT_<n>`, `DEV_URL`, `DEV_HOST`, `HOST`), so
one lease can never overwrite the other's connection string.

## Leasing

```sh
podenv provision <key> --image REF --port <port-inside-the-container> [flags]
```

`--port` is where the daemon listens INSIDE its container (mysql: 3306). The
address you connect to is allocated for you — read it from `.env`, never
hardcode it.

| Flag | What it does |
|---|---|
| `--as VAR` | The `.env` variable to write. Defaults to `<IMAGE>_ADDR`. |
| `--url TPL` | Build a full URL. `{{host}}`, `{{port}}`, `{{password}}`. Double braces — `${port}` is wrong. |
| `--env K=V` | An environment variable for the container. Repeatable. |
| `--password-env NAME` | Put the lease's derived password in the container under `NAME`, and make it available to `{{password}}`. |
| `--volume H:C` | Bind-mount. `/prototypes` is visible to the runtime host, so `--volume /prototypes/myproj:/app` works. |
| `--netns host` | Only when pasta cannot run the image. **There is no port remapping in this mode**, so `--port` must already be free across every lease AND must be **THE EXACT PORT THE DAEMON ITSELF BINDS** — not just "a port inside the container," because there is nothing to remap it to. `provision`'s create path only checks that the container stays RUNNING (deliberately, so a slow image is not punished), never that anything is actually listening on `--port` — so `--netns host --port 23005` for an image that listens on 80 by default returns exit 0, writes a live-looking `.env` entry, leaves the container running, and nothing ever answers on 23005. If the image's own port is configurable (e.g. `traefik/whoami`'s `WHOAMI_PORT_NUMBER`), pass `--env` to make it bind the same port you gave `--port`. |
| `--dedicated "reason"` | Required to override the route gate above. |
| `--env-file PATH` | Where to write/merge the `.env` entry. Defaults to `.env` in the current directory — the worked examples below rely on this default; pass it explicitly only when you are not running from the project's own directory. |

A worked example — MySQL 5.7, which is exactly what this lane exists for:

```sh
podenv provision legacy-erp --image mysql:5.7 --port 3306 \
  --password-env MYSQL_ROOT_PASSWORD \
  --env MYSQL_DATABASE=erp \
  --as MYSQL_URL --url 'mysql://root:{{password}}@{{host}}:{{port}}/erp'
```

Then read `MYSQL_URL` from `.env` like any application would. **Nothing in
your code should know podenv exists.**

## Rules

**`provision` is idempotent — run it freely.** Re-running returns the same
container, the same port and the same password, so it is safe at the start of
every session. It is how you pick a lease back up, not just how you create
one. It probes the lease before touching anything: a container that is
genuinely serving is left alone (re-provisioning never restarts a healthy
daemon just because you called it again). Only a lease that is not answering
gets stopped and started to try to revive it — and if that does not bring it
back, `provision` now FAILS (exit 5) instead of reporting success; nothing is
left half-registered when that happens.

**Never run `podenv release`.** It deletes the container AND its data volumes.
Releasing is the user's decision, not a tidy-up step. It also recycles the
port without touching whatever `.env` the lease's address was written into:
podenv's default address form is a bare `host:port` with no credential, so
if the operator releases a lease, its old `.env` entry can silently start
pointing at a DIFFERENT tenant's daemon once that port gets re-leased.
`release` warns about this at the time; if you see that warning for a lease
you know about, remove the stale variable from the `.env` it was written
into.

**There is no per-lease memory limit.** `podenv provision --memory` is
refused outright (exit 2) rather than silently accepted, because bare
`podman run --memory` is **silently ignored** in this topology — measured:
`memory.max` stays `max`, with zero warnings. Do not rely on a per-lease
limit; there isn't one, and there is no way to fake one. The whole lane
shares one cap, `PODENV_MEM_LIMIT`, set by the operator.

**Prefer the lease over bare `podman run`.** You do have the full `podman`
command and you may use it for builds and throwaway checks. But only leases
are brought back after a restart and only leases appear in `podenv list` /
`devenv list` — anything you start by hand vanishes on the next
`docker compose up` with nothing recording that it existed.

**No `apt-get`, here or anywhere.** Same rule as everywhere else in this
stack: it writes to a container layer that a rebuild throws away.

## Inspecting

`podenv list` shows every lease (image, netns, port, variable, dedicated
reason, idle time) plus podman's disk usage. **There is no disk quota in this
lane** — a hard cap is not possible without privileges this stack does not
grant — so if the store is large, say so to the user rather than deleting
anything.

## Failure

| Exit | Meaning |
|---|---|
| 2 | Bad usage. Three different cases share this code, and only one of them names a devenv command: the **route gate** (devenv already serves this image family) does — read the message and run the `devenv provision` command it gives you. A **reserved `.env` variable name** names a different `--as` instead, not a devenv command. Plain bad usage (missing `--image`, invalid `--netns`, a malformed `--port`) names neither — it just tells you what was wrong with the flags. Read the message; do not assume it always points at devenv. |
| 3 | Three different exhaustion/collision cases share this code, and only two of them are the operator's call. The pool-exhaustion sites (no free port in `PODENV_PORT_BASE`-`PODENV_PORT_RANGE_END`, or the port-claim race lost 5 times running) mean report it to the user; they decide what to release. The third — a **`--netns host` port collision** (two host-netns leases both wanting the same container port, which that mode cannot remap around) — is yours to fix without asking: the message itself says to pick a different `--port` or release the other lease (`podenv list`). Don't burn a round-trip asking permission for something the message already told you how to resolve. |
| 4 | The runtime host or the registry is unreachable. Report it — this is not something you can fix. |
| 5 | The runtime host refused to start (or revive) the lease's container — a bad image, a command that exits immediately, or a daemon that never came back up after a restart attempt. No registry row and no `.env` entry are left behind when this happens on a fresh `provision`. Read the container's logs before retrying blindly. |
