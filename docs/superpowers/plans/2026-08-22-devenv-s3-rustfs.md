# Devenv S3 RustFS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `s3` devenv provider backed by a shared, tenant-isolated RustFS service with idempotent provisioning, truthful release semantics, and clean-install coverage.

**Architecture:** Compose runs one pinned RustFS daemon with its own named volume and loopback-only host port. The Paperclip image carries a pinned `mc` binary; `providers/s3.sh` reconciles one bucket, IAM user, and bucket-scoped policy per lease, while PostgreSQL remains the durable lease registry. S3 is never part of the default provider set and its health never gates Paperclip or non-S3 operations.

**Tech Stack:** Docker Compose, RustFS `1.0.0-rc.3`, MinIO Client `RELEASE.2025-08-13T08-35-41Z`, POSIX shell, PostgreSQL SQL, Bash integration gates, `jq`, `curl`.

**Spec:** `docs/superpowers/specs/2026-08-22-devenv-s3-rustfs-design.md`

## Global Constraints

- Never edit `upstream/` directly; change `patches/`, then run `scripts/prepare.sh` before build/verification.
- RustFS image MUST be `rustfs/rustfs:1.0.0-rc.3@sha256:800cf3f352a0a27e3275ca854a51f0027975d7acc7a0d52089a35bcc9fcbf0b5`.
- `mc` MUST be `RELEASE.2025-08-13T08-35-41Z` from `minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727`.
- `devenv provision <key>` MUST remain equivalent to `--with postgres,valkey`; S3 is opt-in only.
- Paperclip MUST NOT depend on `devenv-s3` health.
- Host S3 publication MUST remain loopback-only; no console and no port 9001 publication.
- Bucket, IAM user, and policy names are exactly `devenv-<key>`.
- Tenant secrets remain derived by `devenv_derive_password "$key" s3`; never store plaintext in PostgreSQL.
- No automatic GC. `devenv release` is the only reclamation path and must preserve registry truth on partial failure.
- Do not reuse, reconfigure, or migrate `buzz-minio`.
- The first release does not promise remote-browser presigned URL reachability, versioning, lifecycle, notifications, replication, object lock, KMS, console, or full MinIO admin compatibility.

---

## File Structure

| File | Responsibility |
|---|---|
| `docker-compose.yml` | `devenv-s3` runtime, volume, loopback port, Paperclip admin connection env |
| `.env.example` | Operator-overridable RustFS root credentials and host port |
| `patches/paperclip/Dockerfile` | Pin and copy the tested `mc` binary into Paperclip |
| `patches/paperclip/devenv/providers/s3.sh` | RustFS probe, bucket/IAM/policy reconciliation, release |
| `patches/paperclip/devenv/devenv` | Parse `s3`, record provider success incrementally, release only registered providers |
| `patches/paperclip/devenv/shared.sh` | Reserve S3 env names and route S3 image families away from podenv |
| `patches/paperclip/devenv/bootstrap.sql` | Add `s3_bucket`, rebuild usage view |
| `tests/devenv-s3.sh` | Structural and live S3 provider gate |
| `tests/audit-bootstrap.sh` | Static producer/order audit |
| `tests/fresh-install.sh` | Port isolation and clean-install execution of the new gate |
| `patches/paperclip/skills/devenv/SKILL.md` | Agent-facing on-demand S3 contract |
| `SETUP.md` | Operator commands and destructive release semantics |
| `AGENTS.md` | Durable architecture, invariants, known compatibility boundary, file map |

---

### Task 1: RustFS Runtime and Pinned Client

**Files:**
- Create: `tests/devenv-s3.sh`
- Modify: `docker-compose.yml:619-750,921-978,1194-1236`
- Modify: `.env.example:158-177`
- Modify: `patches/paperclip/Dockerfile:23-40,143-204`

**Interfaces:**
- Consumes: existing Compose default network; Paperclip runtime image.
- Produces: service `devenv-s3:9000`, volume `devenv-s3-data`, Paperclip env `DEVENV_S3_HOST`, `DEVENV_S3_PORT`, `DEVENV_S3_ROOT_USER`, `DEVENV_S3_ROOT_PASSWORD`, executable `/usr/local/bin/mc`.

- [ ] **Step 1: Add the structural gate and make it executable**

Create the script header and exact resolved-compose assertions:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. ./scripts/load-env.sh; opc_load_env ./.env

PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }

COMPOSE_JSON="$(docker compose config --format json)"
check "RustFS image is pinned" jq -e '
  .services["devenv-s3"].image ==
  "rustfs/rustfs:1.0.0-rc.3@sha256:800cf3f352a0a27e3275ca854a51f0027975d7acc7a0d52089a35bcc9fcbf0b5"
' <<<"$COMPOSE_JSON"
check "RustFS data uses a named volume" jq -e '
  any(.services["devenv-s3"].volumes[];
      .source == "devenv-s3-data" and .target == "/data")
' <<<"$COMPOSE_JSON"
check "S3 host port is loopback only" jq -e '
  any(.services["devenv-s3"].ports[];
      .target == 9000 and .host_ip == "127.0.0.1")
' <<<"$COMPOSE_JSON"
check "RustFS console is disabled" jq -e '
  .services["devenv-s3"].environment.RUSTFS_CONSOLE_ENABLE == "false" and
  all(.services["devenv-s3"].ports[]; .target != 9001)
' <<<"$COMPOSE_JSON"
check "Paperclip is not health-gated by RustFS" jq -e '
  .services.paperclip.depends_on["devenv-s3"] == null
' <<<"$COMPOSE_JSON"
```

Run:

```bash
chmod +x tests/devenv-s3.sh
tests/devenv-s3.sh
```

Expected: the five new checks report `FAIL` because `devenv-s3` does not exist.

- [ ] **Step 2: Pin and copy `mc` in the Paperclip Dockerfile**

Add a global client stage after `nix-seed`:

```dockerfile
# RustFS provisioning client. This exact build is covered by tests/devenv-s3.sh.
FROM minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727 AS minio-client
```

In the production OPC overlay, copy only the binary:

```dockerfile
COPY --from=minio-client /usr/bin/mc /usr/local/bin/mc
```

Do not install `mc` through nix-seed: that would duplicate the client into every service image.

- [ ] **Step 3: Add `devenv-s3` and Paperclip connection settings**

Add beside `devenv-pg` / `devenv-valkey`:

```yaml
  devenv-s3:
    image: rustfs/rustfs:1.0.0-rc.3@sha256:800cf3f352a0a27e3275ca854a51f0027975d7acc7a0d52089a35bcc9fcbf0b5
    restart: unless-stopped
    environment:
      RUSTFS_VOLUMES: /data
      RUSTFS_ADDRESS: 0.0.0.0:9000
      RUSTFS_CONSOLE_ENABLE: "false"
      RUSTFS_ACCESS_KEY: ${DEVENV_S3_ROOT_USER:-devenv-admin}
      RUSTFS_SECRET_KEY: ${DEVENV_S3_ROOT_PASSWORD:-devenv-object-storage}
    ports:
      - "127.0.0.1:${DEVENV_S3_PORT:-9002}:9000"
    volumes:
      - devenv-s3-data:/data
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:9000/health"]
      interval: 5s
      timeout: 5s
      retries: 30
```

Add `devenv-s3-data:` to top-level volumes. Add these Paperclip environment entries, but no `depends_on` entry:

```yaml
      DEVENV_S3_HOST: devenv-s3
      DEVENV_S3_PORT: "9000"
      DEVENV_S3_ROOT_USER: ${DEVENV_S3_ROOT_USER:-devenv-admin}
      DEVENV_S3_ROOT_PASSWORD: ${DEVENV_S3_ROOT_PASSWORD:-devenv-object-storage}
```

- [ ] **Step 4: Document deploy-time overrides in `.env.example`**

Add to the active devenv section:

```dotenv
DEVENV_S3_ROOT_USER=devenv-admin
DEVENV_S3_ROOT_PASSWORD=
DEVENV_S3_PORT=9002
```

The comments must state: defaults are scratch credentials, host publication is `127.0.0.1`, changing root credentials after RustFS initializes requires explicit operator reconciliation, and tenant secrets still come from `DEVENV_SECRET_SALT`.

- [ ] **Step 5: Re-run the structural test**

Run:

```bash
tests/devenv-s3.sh
```

Expected: five structural checks pass; the script exits non-zero only if its final summary is not yet present. Add this footer now:

```bash
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 6: Build and smoke-test only the new runtime boundary**

Run:

```bash
scripts/prepare.sh
docker compose build paperclip
docker compose up -d devenv-s3 paperclip
docker compose exec -T paperclip mc --version
curl -fsS "http://127.0.0.1:${DEVENV_S3_PORT:-9002}/health"
```

Expected: `mc version RELEASE.2025-08-13T08-35-41Z`; health request exits 0. Paperclip starts even if `devenv-s3` is subsequently stopped.

- [ ] **Step 7: Commit the runtime boundary**

```bash
git add docker-compose.yml .env.example patches/paperclip/Dockerfile tests/devenv-s3.sh
git commit -m "feat: add RustFS devenv backend"
```

---

### Task 2: S3 Provider, Registry, and Core Isolation

**Files:**
- Modify: `tests/devenv-s3.sh`
- Create: `patches/paperclip/devenv/providers/s3.sh`
- Modify: `patches/paperclip/devenv/shared.sh:15-67`
- Modify: `patches/paperclip/devenv/bootstrap.sql:6-77`
- Modify: `patches/paperclip/devenv/devenv:20-249,291-305`

**Interfaces:**
- Consumes: Task 1 env values and `/usr/local/bin/mc`; existing `devenv_derive_password`, `devenv_psql_control`, `devenv_env_merge`.
- Produces: `s3_probe`, `s3_provision <key> <slug>`, `s3_release <key> <slug>`; registry column `s3_bucket`; six S3 `.env` values.

- [ ] **Step 1: Extend the gate with failing provision and isolation checks**

Add unique gate keys and cleanup that only touches test-owned leases:

```bash
LEASE_A="s3-gate-a"
LEASE_B="s3-gate-b"
ENV_A="/tmp/${LEASE_A}.env"
ENV_B="/tmp/${LEASE_B}.env"
pc() { docker compose exec -T -u node paperclip "$@"; }
cleanup() {
  pc devenv release "$LEASE_A" >/dev/null 2>&1 || true
  pc devenv release "$LEASE_B" >/dev/null 2>&1 || true
  pc devenv release s3-pg-only >/dev/null 2>&1 || true
  pc devenv release s3-default >/dev/null 2>&1 || true
  pc rm -rf "$ENV_A" "$ENV_B" /tmp/s3-gate-object /tmp/s3-multipart /tmp/s3-pg-only.env /tmp/s3-default.env /tmp/mc-a /tmp/mc-b >/dev/null 2>&1 || true
}
trap cleanup EXIT
```

Add checks which require real command success, not empty output:

```bash
check "S3 lease A provisions" pc devenv provision "$LEASE_A" --with s3 --env-file "$ENV_A"
check "S3 lease B provisions" pc devenv provision "$LEASE_B" --with s3 --env-file "$ENV_B"
check "S3 env contract is complete" pc sh -ec '
  f=/tmp/s3-gate-a.env
  for k in AWS_ENDPOINT_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION S3_BUCKET S3_FORCE_PATH_STYLE; do
    grep -q "^${k}=" "$f" || exit 1
  done
'
```

Configure isolated `mc` aliases inside Paperclip with temporary config directories, PUT into A, and assert A cannot access B:

```bash
check "tenant A writes its bucket" pc sh -ec '
  . /tmp/s3-gate-a.env
  export MC_CONFIG_DIR=/tmp/mc-a
  mc alias set tenant "$AWS_ENDPOINT_URL" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" --api S3v4 --path on >/dev/null
  printf gate >/tmp/s3-gate-object
  mc cp /tmp/s3-gate-object "tenant/$S3_BUCKET/object" >/dev/null
'
check "tenant A cannot list tenant B" pc sh -ec '
  . /tmp/s3-gate-a.env; other=$(sed -n "s/^S3_BUCKET=//p" /tmp/s3-gate-b.env)
  export MC_CONFIG_DIR=/tmp/mc-a
  ! mc ls "tenant/$other" >/tmp/cross.out 2>&1 && grep -qi "Access Denied" /tmp/cross.out
'
```

Run:

```bash
tests/devenv-s3.sh
```

Expected: provision fails with `unknown provider 's3'`.

- [ ] **Step 2: Add S3 env ownership and podenv routing**

In `devenv_reserved_env_names`, append exactly:

```text
AWS_ENDPOINT_URL
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_REGION
S3_BUCKET
S3_FORCE_PATH_STYLE
```

In `devenv_provider_image_families`, append:

```text
s3=s3
minio=s3
rustfs=s3
```

Update the surrounding comments so the lists remain mechanically derived from providers.

- [ ] **Step 3: Add the registry column and usage-view projection**

Add `s3_bucket text UNIQUE` to new tables and the idempotent existing-deployment statement:

```sql
ALTER TABLE devenv_tenant ADD COLUMN IF NOT EXISTS s3_bucket text UNIQUE;
```

Project `t.s3_bucket` in `devenv_usage`, and include `s3_bucket` in `cmd_list` immediately after `valkey_db`. Do not call RustFS from the view or list command.

- [ ] **Step 4: Implement the S3 provider**

Use `MC_HOST_devenv` rather than a persistent alias file. URL-encode both credential components with `jq @uri`; this supports operator overrides containing URL-reserved characters and leaves no root credential under `/tmp`:

```sh
DEVENV_S3_HOST="${DEVENV_S3_HOST:-devenv-s3}"
DEVENV_S3_PORT="${DEVENV_S3_PORT:-9000}"
DEVENV_S3_ROOT_USER="${DEVENV_S3_ROOT_USER:-devenv-admin}"
DEVENV_S3_ROOT_PASSWORD="${DEVENV_S3_ROOT_PASSWORD:-devenv-object-storage}"

s3_mc_init() {
    _s3mi_user="$(jq -nr --arg v "$DEVENV_S3_ROOT_USER" '$v|@uri')" || return 1
    _s3mi_password="$(jq -nr --arg v "$DEVENV_S3_ROOT_PASSWORD" '$v|@uri')" || return 1
    MC_HOST_devenv="http://${_s3mi_user}:${_s3mi_password}@${DEVENV_S3_HOST}:${DEVENV_S3_PORT}"
    export MC_HOST_devenv
}

s3_probe() {
    s3_mc_init >/dev/null 2>&1 && mc ready devenv >/dev/null 2>&1
}

s3_name() { printf 'devenv-%s\n' "$1"; }
```

`S3_provision` must:

1. call `mc mb --ignore-existing`;
2. call `mc admin user add` with the derived secret;
3. write a private temporary policy file containing the exact bucket/object actions from the spec;
4. call `mc admin policy create` and `mc admin policy attach --user`;
5. remove the policy temp file;
6. print exactly the six `.env` lines.

Use this policy body, substituting only the validated bucket name:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::devenv-KEY"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::devenv-KEY/*"]
    }
  ]
}
```

Every failed `mc` mutation must call `die "S3 reconciliation failed for '$_s3p_key'" 4`; never fall back to root tenant credentials or `buzz-minio`.

Implement `s3_release` in the same file. It must initialize the alias, require successful JSON listings, and only remove confirmed-present resources:

```sh
_users="$(mc admin user list devenv --json)" || die "cannot list S3 users" 4
_policies="$(mc admin policy list devenv --json)" || die "cannot list S3 policies" 4
_buckets="$(mc ls devenv --json)" || die "cannot list S3 buckets" 4
```

Use `jq -e --arg name "$_s3r_name"` with the RustFS rc.3 fields `.accessKey == $name`, `.policy == $name`, and `.key == ($name + "/")`. Remove a present bucket with `mc rb --force`, then a present user with `mc admin user remove`, then a present policy with `mc admin policy remove`. A successful listing without a match is confirmed absent; a listing or mutation error must exit 4.

- [ ] **Step 5: Register `s3` and make provision state incremental**

In provider parsing, accept `s3` with no `=arg`; keep `with="postgres,valkey"` unchanged. Probe only when selected:

```sh
case " $providers " in
  *" valkey "*) valkey_probe || die "devenv-valkey unreachable at $DEVENV_VALKEY_HOST:$DEVENV_VALKEY_PORT" 4 ;;
esac
case " $providers " in
  *" s3 "*) s3_probe || die "devenv-s3 unreachable at $DEVENV_S3_HOST:$DEVENV_S3_PORT" 4 ;;
esac
```

Insert new rows with `ARRAY[]::text[]`, not the requested list. After each provider succeeds, persist its provider state before moving to the next:

```sh
devenv_registry_provider_add() {
    devenv_psql_control -v ON_ERROR_STOP=1 -c "
      UPDATE devenv_tenant
         SET providers = ARRAY(
               SELECT DISTINCT p FROM unnest(providers || ARRAY['$2']) AS p
               ORDER BY p
             ),
             last_seen_at = now()
       WHERE key = '$1'" >/dev/null
}
```

For `s3`, set `s3_bucket = 'devenv-$key'` in the same successful-provider update. Preserve the existing valkey DB and HTTP allocation updates. Only merge `.env` after the complete requested loop succeeds.

- [ ] **Step 6: Build and run the focused core gate**

Run:

```bash
scripts/prepare.sh
docker compose up -d --build paperclip devenv-s3
tests/devenv-s3.sh
```

Expected: provisioning, six env names, own-bucket write, and cross-bucket LIST denial pass. Query the registry directly and confirm both rows carry `providers={s3}` and non-null `s3_bucket`.

- [ ] **Step 7: Commit the provider core**

```bash
git add patches/paperclip/devenv tests/devenv-s3.sh
git commit -m "feat: provision isolated S3 leases"
```

---

### Task 3: Truthful Release and Failure Isolation

**Files:**
- Modify: `tests/devenv-s3.sh`
- Modify: `patches/paperclip/devenv/devenv:128-148,252-277`
- Modify: `patches/paperclip/devenv/providers/s3.sh`
- Modify: `patches/paperclip/devenv/providers/postgres.sh:52-60`
- Modify: `patches/paperclip/devenv/providers/valkey.sh:31-40`
- Modify: `patches/paperclip/devenv/providers/http.sh:124-132`

**Interfaces:**
- Consumes: registry `providers`, provider release functions from Task 2.
- Produces: `devenv_registry_providers`, `devenv_registry_provider_remove`; release retries only unfinished providers and deletes the row only when empty.

- [ ] **Step 1: Add failing release and unavailable-backend tests**

Extend the gate with these observable contracts:

```bash
check "S3-only reprovision is byte-stable" pc sh -ec '
  cp /tmp/s3-gate-a.env /tmp/s3-gate-a.before
  devenv provision s3-gate-a --with s3 --env-file /tmp/s3-gate-a.env >/dev/null
  cmp /tmp/s3-gate-a.before /tmp/s3-gate-a.env
'

check "Postgres-only provision ignores dead S3" docker compose exec -T -u node \
  -e DEVENV_S3_HOST=127.0.0.1 -e DEVENV_S3_PORT=1 paperclip \
  devenv provision s3-pg-only --with postgres --env-file /tmp/s3-pg-only.env

check "default lease remains postgres,valkey" pc sh -ec '
  devenv provision s3-default --env-file /tmp/s3-default.env >/dev/null
  ! grep -q "^S3_" /tmp/s3-default.env
  providers=$(PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql \
    -h "$DEVENV_PG_HOST" -p "$DEVENV_PG_PORT" -U "$DEVENV_PG_ADMIN_USER" \
    -d "${DEVENV_CONTROL_DB:-devenv_control}" -tAc \
    "SELECT array_to_string(providers, '"'"','"'"') FROM devenv_tenant WHERE key = '"'"'s3-default'"'"'")
  [ "$(printf %s "$providers" | tr -d "[:space:]")" = "postgres,valkey" ]
'

check "failed S3 release retains registry truth" docker compose exec -T -u node \
  paperclip sh -ec '
    if DEVENV_S3_HOST=127.0.0.1 DEVENV_S3_PORT=1 devenv release s3-gate-a; then exit 1; fi
    PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql \
      -h "$DEVENV_PG_HOST" -p "$DEVENV_PG_PORT" -U "$DEVENV_PG_ADMIN_USER" \
      -d "${DEVENV_CONTROL_DB:-devenv_control}" -tAc \
      "SELECT s3_bucket IS NOT NULL AND '"'"'s3'"'"' = ANY(providers)
         FROM devenv_tenant WHERE key = '"'"'s3-gate-a'"'"'" | grep -q t
  '

check "dead S3 provision exits 4 without state" docker compose exec -T -u node \
  paperclip sh -ec '
    rm -f /tmp/s3-dead.env
    set +e
    DEVENV_S3_HOST=127.0.0.1 DEVENV_S3_PORT=1 \
      devenv provision s3-dead --with s3 --env-file /tmp/s3-dead.env >/tmp/s3-dead.out 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 4 ] && [ ! -e /tmp/s3-dead.env ]
    rows=$(PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql \
      -h "$DEVENV_PG_HOST" -p "$DEVENV_PG_PORT" -U "$DEVENV_PG_ADMIN_USER" \
      -d "${DEVENV_CONTROL_DB:-devenv_control}" -tAc \
      "SELECT count(*) FROM devenv_tenant WHERE key = '"'"'s3-dead'"'"'")
    [ "$(printf %s "$rows" | tr -d "[:space:]")" = 0 ]
  '

check "devenv list ignores dead S3" docker compose exec -T -u node \
  -e DEVENV_S3_HOST=127.0.0.1 -e DEVENV_S3_PORT=1 paperclip devenv list

check "Postgres-only release ignores dead S3" docker compose exec -T -u node \
  -e DEVENV_S3_HOST=127.0.0.1 -e DEVENV_S3_PORT=1 paperclip \
  devenv release s3-pg-only
```

Run `tests/devenv-s3.sh`. Expected: byte stability may pass, but provider-aware release checks fail because `devenv_teardown` still calls every provider and deletes one row wholesale.

- [ ] **Step 2: Add exact registry transition helpers**

Implement:

```sh
devenv_registry_providers() {
    devenv_psql_control -tAc \
      "SELECT array_to_string(providers, ' ') FROM devenv_tenant WHERE key = '$1'" \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

devenv_registry_provider_remove() {
    _rpr_key="$1"; _rpr_provider="$2"
    devenv_psql_control -v ON_ERROR_STOP=1 -c "
      UPDATE devenv_tenant
         SET providers = array_remove(providers, '$_rpr_provider'),
             valkey_db = CASE WHEN '$_rpr_provider' = 'valkey' THEN NULL ELSE valkey_db END,
             http_port_start = CASE WHEN '$_rpr_provider' = 'http' THEN NULL ELSE http_port_start END,
             http_port_count = CASE WHEN '$_rpr_provider' = 'http' THEN 0 ELSE http_port_count END,
             http_exposed_at = CASE WHEN '$_rpr_provider' = 'http' THEN NULL ELSE http_exposed_at END,
             s3_bucket = CASE WHEN '$_rpr_provider' = 's3' THEN NULL ELSE s3_bucket END
       WHERE key = '$_rpr_key'" >/dev/null
}
```

- [ ] **Step 3: Make teardown provider-aware and resumable**

Replace unconditional calls with:

```sh
devenv_teardown() {
    _td_key="$1"; _td_slug="$2"
    _td_providers="$(devenv_registry_providers "$_td_key")"
    for _td_provider in $_td_providers; do
        "${_td_provider}_release" "$_td_key" "$_td_slug" \
          || die "release of provider '$_td_provider' failed for '$_td_key'" 4
        devenv_registry_provider_remove "$_td_key" "$_td_provider"
    done
    devenv_psql_control -v ON_ERROR_STOP=1 -c \
      "DELETE FROM devenv_tenant WHERE key = '$_td_key' AND cardinality(providers) = 0" >/dev/null
}
```

The provision rollback uses the same function; because new rows begin with an empty array and add only completed providers, it tears down only completed work.

- [ ] **Step 4: Harden existing non-S3 release functions**

For PostgreSQL and Valkey, remove blanket `|| true` from destructive operations. Keep idempotency through `DROP DATABASE IF EXISTS`, `DROP ROLE IF EXISTS`, and Valkey's successful zero-count `ACL DELUSER`; run SQL with `ON_ERROR_STOP=1`. `http_release` remains a successful no-op because registry columns are its only state.

Retain the S3 list-before-remove logic from Task 2. The release failure test now proves that an unreachable backend cannot be mistaken for confirmed absence.

- [ ] **Step 5: Verify failure isolation and resumability**

Run:

```bash
scripts/prepare.sh
docker compose up -d --build paperclip
tests/devenv-s3.sh
```

Expected: dead-S3 S3 release exits 4 and retains `s3`; dead-S3 PostgreSQL-only provision/release succeeds; a subsequent normal release removes S3 resources and row; a second release reports `(absent)` and exits 0.

- [ ] **Step 6: Commit lifecycle correctness**

```bash
git add patches/paperclip/devenv tests/devenv-s3.sh
git commit -m "fix: preserve devenv provider release truth"
```

---

### Task 4: Complete the S3 Data-Plane Gate

**Files:**
- Modify: `tests/devenv-s3.sh`
- Modify if a gate exposes a missing permission/error mapping: `patches/paperclip/devenv/providers/s3.sh`

**Interfaces:**
- Consumes: working tenant aliases and release semantics from Tasks 2–3.
- Produces: permanent evidence for CRUD, multipart, presigned download, cross-tenant denial, and named-volume persistence.

- [ ] **Step 1: Add GET, DELETE, and negative GET/PUT checks**

Use `mc cat`, `mc rm`, and a temporary B alias. Every negative assertion must require both non-zero status and `Access Denied`; transport failure is not proof of isolation.

```bash
check "tenant A reads its object" pc sh -ec '
  . /tmp/s3-gate-a.env; export MC_CONFIG_DIR=/tmp/mc-a
  [ "$(mc cat "tenant/$S3_BUCKET/object")" = gate ]
'
check "tenant A cannot PUT tenant B" pc sh -ec '
  . /tmp/s3-gate-a.env; other=$(sed -n "s/^S3_BUCKET=//p" /tmp/s3-gate-b.env)
  export MC_CONFIG_DIR=/tmp/mc-a
  if mc cp /tmp/s3-gate-object "tenant/$other/forbidden" >/tmp/cross-put.out 2>&1; then exit 1; fi
  grep -qi "Access Denied" /tmp/cross-put.out
'
check "tenant A cannot GET tenant B" pc sh -ec '
  . /tmp/s3-gate-a.env; other=$(sed -n "s/^S3_BUCKET=//p" /tmp/s3-gate-b.env)
  export MC_CONFIG_DIR=/tmp/mc-a
  if mc cat "tenant/$other/missing" >/tmp/cross-get.out 2>&1; then exit 1; fi
  grep -qi "Access Denied" /tmp/cross-get.out
'
check "tenant A deletes its object" pc sh -ec '
  . /tmp/s3-gate-a.env; export MC_CONFIG_DIR=/tmp/mc-a
  mc rm "tenant/$S3_BUCKET/object" >/dev/null
  if mc stat "tenant/$S3_BUCKET/object" >/tmp/own-delete.out 2>&1; then exit 1; fi
  grep -Eqi "not exist|not found" /tmp/own-delete.out
'
```


- [ ] **Step 2: Add a real multipart upload**

Create a 70 MiB sparse-zero payload in Paperclip, upload it, and verify size through `mc stat --json`:

```bash
check "tenant multipart upload succeeds" pc sh -ec '
  . /tmp/s3-gate-a.env; export MC_CONFIG_DIR=/tmp/mc-a
  dd if=/dev/zero of=/tmp/s3-multipart bs=1M count=70 status=none
  mc cp /tmp/s3-multipart "tenant/$S3_BUCKET/multipart" >/dev/null
  mc stat --json "tenant/$S3_BUCKET/multipart" | jq -e ".size == 73400320" >/dev/null
'
```

- [ ] **Step 3: Add credentialless presigned download**

Generate the share URL with tenant credentials, then invoke `curl` with AWS credentials removed:

```bash
check "presigned download needs no credentials" pc sh -ec '
  . /tmp/s3-gate-a.env; export MC_CONFIG_DIR=/tmp/mc-a
  url=$(mc share download --json --expire 5m "tenant/$S3_BUCKET/multipart" | jq -er .share)
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  [ "$(curl -fsS "$url" | wc -c)" -eq 73400320 ]
'
```

The URL is exercised inside the Docker network. Do not rewrite it into a public URL or claim remote-browser reachability.

- [ ] **Step 4: Prove persistence through force-recreate**

After upload, recreate RustFS from the host test process and wait on the resolved host port:

```bash
check "RustFS force-recreate succeeds" docker compose up -d --force-recreate devenv-s3
ready=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${DEVENV_S3_PORT:-9002}/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" -eq 1 ]; then pass "RustFS returns healthy"; else fail "RustFS returns healthy"; fi
check "object and IAM survive recreate" pc sh -ec '
  . /tmp/s3-gate-a.env; export MC_CONFIG_DIR=/tmp/mc-a
  mc stat "tenant/$S3_BUCKET/multipart" >/dev/null
'
```

- [ ] **Step 5: Prove targeted release**

Release A, then obtain successful root listings and assert A is absent while B remains:

```bash
check "tenant A release succeeds" pc devenv release "$LEASE_A"
check "release removes only tenant A" pc sh -ec '
  . /usr/local/lib/devenv/providers/s3.sh
  s3_mc_init
  buckets=$(mc ls devenv --json)
  users=$(mc admin user list devenv --json)
  policies=$(mc admin policy list devenv --json)
  ! printf "%s\n" "$buckets" | jq -e --arg n "devenv-s3-gate-a/" "select(.key == \$n)" >/dev/null
  ! printf "%s\n" "$users" | jq -e --arg n "devenv-s3-gate-a" "select(.accessKey == \$n)" >/dev/null
  ! printf "%s\n" "$policies" | jq -e --arg n "devenv-s3-gate-a" "select(.policy == \$n)" >/dev/null
  printf "%s\n" "$buckets" | jq -e --arg n "devenv-s3-gate-b/" "select(.key == \$n)" >/dev/null
'
check "tenant B still writes after A release" pc sh -ec '
  . /tmp/s3-gate-b.env
  export MC_CONFIG_DIR=/tmp/mc-b
  mc alias set tenant-b "$AWS_ENDPOINT_URL" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" --api S3v4 --path on >/dev/null
  printf still-live | mc pipe "tenant-b/$S3_BUCKET/after-a-release" >/dev/null
  [ "$(mc cat "tenant-b/$S3_BUCKET/after-a-release")" = still-live ]
'
```

The EXIT trap releases B.

- [ ] **Step 6: Run and commit the complete focused gate**

Run:

```bash
scripts/prepare.sh
docker compose up -d --build paperclip devenv-s3
tests/devenv-s3.sh
```

Expected: all structural and live checks pass; both gate rows and all gate buckets/users/policies are absent afterward.

```bash
git add tests/devenv-s3.sh patches/paperclip/devenv/providers/s3.sh
git commit -m "test: cover devenv S3 lifecycle"
```

---

### Task 5: Clean Install, Audit, Agent Contract, and Operator Docs

**Files:**
- Modify: `tests/audit-bootstrap.sh`
- Modify: `tests/fresh-install.sh:72-84,168-203,398-414,476-486`
- Modify: `patches/paperclip/skills/devenv/SKILL.md`
- Modify: `SETUP.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: complete feature and gate from Tasks 1–4.
- Produces: clean-machine port isolation, bootstrap audit, agent-facing usage contract, operator runbook.

- [ ] **Step 1: Write failing audit checks**

Add exact producer checks to `tests/audit-bootstrap.sh` using its existing `has` helper:

```bash
has "devenv S3 durable volume" docker-compose.yml 'devenv-s3-data:/data'
has "devenv S3 root credential source" docker-compose.yml 'DEVENV_S3_ROOT_PASSWORD'
has "devenv S3 schema producer" patches/paperclip/devenv/bootstrap.sql 'ADD COLUMN IF NOT EXISTS s3_bucket'
has "paperclip carries pinned mc" patches/paperclip/Dockerfile 'RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349e'
```

Run `tests/audit-bootstrap.sh`. Expected: any missing producer check fails before the remaining documentation changes.

- [ ] **Step 2: Add the new gate and host port to fresh-install rehearsal**

Make these exact changes:

- append `DEVENV_S3_PORT` to the initial inherited-env `unset` list;
- add `DEVENV_S3_PORT:9002` to `PORT_KEYS`;
- append `tests/devenv-s3.sh` to `GATES`;
- leave `DEVENV_S3_ROOT_*` at clean-install defaults; do not copy live secrets;
- ensure the gate relocatability preflight sees `opc_load_env ./.env` in the new script.

Run:

```bash
tests/fresh-install.sh --dry-run
```

Expected: output includes an offset `DEVENV_S3_PORT`; it does not collide with the live stack and recognizes `tests/devenv-s3.sh` as relocatable.

- [ ] **Step 3: Update the agent skill with the exact opt-in contract**

Add `s3` to description and examples. State all of the following explicitly:

```text
Default remains postgres,valkey.
Use: devenv provision <key> --with s3
Use: devenv provision <key> --with postgres,s3
Read: AWS_ENDPOINT_URL, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
      AWS_REGION, S3_BUCKET, S3_FORCE_PATH_STYLE.
Wire S3_BUCKET and path-style explicitly; not every SDK reads those two names.
Presigned URLs are internal/host-loopback only in this release.
Never use buzz-minio and never run devenv release as an agent.
Exit 4 means the selected backend cannot complete; do not retry-loop or fall back.
```

Update the inspecting section so `devenv list` shows the bucket but does not contact RustFS for size.

- [ ] **Step 4: Update operator documentation**

In `SETUP.md`, document:

```bash
docker compose exec -u node paperclip devenv provision demo --with s3
docker compose exec -u node paperclip devenv list
docker compose exec -it paperclip devenv release demo
```

Add a host inspection example that reads tenant credentials and substitutes host endpoint `http://127.0.0.1:${DEVENV_S3_PORT:-9002}`. State that release force-deletes all objects and remains manual.

For the single existing deployment, include one pasteable recreate sequence rather than a migration script:

```bash
scripts/prepare.sh
docker compose up -d --build paperclip
docker compose up -d devenv-s3
```

- [ ] **Step 5: Update durable repository guidance**

In `AGENTS.md`, update:

- architecture: `devenv-s3`, RustFS pin, bucket/IAM-per-lease model;
- on-demand invariant: S3 is not default and cannot health-gate Paperclip/non-S3 leases;
- lifecycle: named volume, no GC, operator-only release;
- known pitfall: required path-style, loopback-only presigned URLs, `mc admin info` unsupported despite required IAM commands working;
- common commands: `--with s3`, S3 host inspection, `tests/devenv-s3.sh`;
- file map: `providers/s3.sh` and new gate;
- fresh-install gate count/list.

Do not change Buzz's `minio/minio:latest` in this task; that is separate deployment ownership and scope.

- [ ] **Step 6: Run focused documentation/bootstrap checks and commit**

Run:

```bash
scripts/prepare.sh
tests/audit-bootstrap.sh
tests/fresh-install.sh --dry-run
docker compose config --quiet
```

Expected: all exit 0.

```bash
git add tests/audit-bootstrap.sh tests/fresh-install.sh \
  patches/paperclip/skills/devenv/SKILL.md SETUP.md AGENTS.md
git commit -m "docs: publish devenv S3 workflow"
```

---

### Task 6: End-to-End Verification

**Files:**
- Verify only; modify a source file only when a command exposes a defect, then rerun the failed command before continuing.

**Interfaces:**
- Consumes: all previous tasks.
- Produces: behavioral evidence for the complete spec and clean-install contract.

- [ ] **Step 1: Rebuild from the authoritative patches**

Run:

```bash
scripts/prepare.sh
docker compose up -d --build paperclip devenv-s3
```

Expected: Paperclip and RustFS become healthy; RustFS is not a Paperclip dependency edge.

- [ ] **Step 2: Run the focused S3 gate**

```bash
tests/devenv-s3.sh
```

Expected: every structural, on-demand, isolation, multipart, presigned, recreate, failure, and targeted-release check passes; summary reports zero failures.

- [ ] **Step 3: Run existing regression gates**

```bash
tests/audit-bootstrap.sh
tests/connectivity.sh
tests/scientist.sh
tests/podenv.sh
```

Expected: all four exit 0. This proves the general provider lifecycle changes did not regress PostgreSQL, Valkey, HTTP previews, expert leases, or podenv routing.

- [ ] **Step 4: Run the clean-machine rehearsal**

```bash
tests/fresh-install.sh
```

Expected: `scripts/setup.sh`, audit, connectivity, scientist, podenv, and devenv-s3 gates all report PASS; rehearsal teardown removes only its offset compose project and volumes.

- [ ] **Step 5: Inspect final runtime contract**

Run:

```bash
docker compose config --format json | jq -e '
  .services["devenv-s3"].ports[0].host_ip == "127.0.0.1" and
  .services.paperclip.depends_on["devenv-s3"] == null
'
docker compose exec -T paperclip mc --version
docker compose exec -T -u node paperclip devenv list
```

Expected: jq returns true; `mc` reports the pinned release; list succeeds and contains no gate leases.

If a verification command exposes a defect, return to the task that owns that contract, add or tighten its focused regression assertion, implement the correction, rerun that focused gate, and repeat Task 6 from Step 1. Do not create an empty verification commit.
