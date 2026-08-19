# Buzz Agent Owner Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one safe command that binds the front-door Hermes agent to a named Buzz human and makes owner-scoped ACP activity survive every redeploy, including `docker compose down -v`.

**Architecture:** NIP-OA is the only ownership authority. A network-isolated signing helper reads the owner pkey through stdin and emits a public attestation; the host script verifies the selected account, writes only public configuration, and recreates frontdoor. Frontdoor then republishes attested kind 0 and kind 10100 records on every boot, while the relay derives its DB mapping from the same attestation.

**Tech Stack:** POSIX shell, Docker Compose, Rust (`buzz_sdk::nip_oa`), PostgreSQL 17, Buzz CLI/Nostr kinds 0, 10100, and 24200.

## Global Constraints

- Never modify `upstream/` directly; image changes live under `patches/buzz/` and reach the build context through `scripts/prepare.sh`.
- The owner pkey must never enter `.env`, Compose configuration, mounts, argv, logs, or the database.
- The signer may receive the pkey only through stdin in a disposable `docker run --rm -i --network none` process.
- Name lookup must resolve exactly one active human; missing, ambiguous, or agent identities fail before configuration changes.
- The generated attestation must verify for both the exact front-door agent pubkey and the resolved owner pubkey.
- `BUZZ_OWNER_KEY_FILE` is host-only and must never be passed to a Compose service.
- Existing ownership by a different owner fails loudly; no implicit ownership rotation.
- Reconciliation must publish both kind 0 and kind 10100 with the ambient `BUZZ_AUTH_TAG`.
- Current hotfix state is intentional: `.env` already has the working public `BUZZ_AUTH_TAG`, and `docker-compose.yml` already passes it to frontdoor. Preserve both while converting the repair into tested permanent behavior.

---

### Task 1: Network-Isolated NIP-OA Signer

**Files:**
- Create: `patches/buzz/opc-nip-oa-sign.rs`
- Modify: `patches/buzz/Dockerfile:43-74,136-160`
- Create: `scripts/test-buzz-owner-signer.sh`

**Interfaces:**
- Consumes stdin: one trimmed owner secret in 64-hex or nsec format.
- Consumes argv: `opc-nip-oa-sign <agent-pubkey-hex> <expected-owner-pubkey-hex>`.
- Produces stdout: exactly one JSON NIP-OA tag `['auth', owner, '', signature]` serialized with double quotes.
- Produces exit codes: `0` success, `2` malformed input, `3` derived-owner mismatch; stderr contains no secret.

- [ ] **Step 1: Write the failing signer smoke test**

Create `scripts/test-buzz-owner-signer.sh` with deterministic secp256k1 fixtures: owner secret `0000000000000000000000000000000000000000000000000000000000000001`, owner x-only public key `79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798`, and agent secret `2`'s x-only public key `c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5`. The test builds the `opc-frontdoor` target, runs the helper through stdin, validates the returned JSON shape, exercises owner mismatch, and asserts captured stdout/stderr do not contain the owner secret. Cryptographic verification itself is a Rust unit test beside `run`, using `nip_oa::verify_auth_tag` against the fixed agent public key.

```sh
#!/bin/sh
set -eu
IMAGE="${IMAGE_PREFIX:-opc}/frontdoor:owner-signer-test"
OWNER_SECRET="0000000000000000000000000000000000000000000000000000000000000001"
OWNER_PUBKEY="79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
AGENT_PUBKEY="c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"

docker build --target opc-frontdoor -t "$IMAGE" \
  -f upstream/buzz/opc/Dockerfile upstream/buzz

tag="$(printf '%s\n' "$OWNER_SECRET" | docker run --rm -i --network none \
  --entrypoint /usr/local/bin/opc-nip-oa-sign "$IMAGE" \
  "$AGENT_PUBKEY" "$OWNER_PUBKEY")"
printf '%s' "$tag" | jq -e --arg owner "$OWNER_PUBKEY" \
  '.[0] == "auth" and .[1] == $owner and .[2] == "" and (.[3] | length == 128)' >/dev/null
```

The mismatch invocation passes secret `1` on stdin but expected owner pubkey `f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9` (secret `3`'s x-only public key), and must exit `3`.

- [ ] **Step 2: Run the signer test and verify RED**

Run:

```bash
scripts/prepare.sh
sh scripts/test-buzz-owner-signer.sh
```

Expected: FAIL because `/usr/local/bin/opc-nip-oa-sign` does not exist in the image.

- [ ] **Step 3: Implement the stdin-only signer**

Create `patches/buzz/opc-nip-oa-sign.rs` around this interface:

```rust
use std::io::{self, Read};
use buzz_sdk::nip_oa;
use nostr::{Keys, PublicKey};

fn run(agent_hex: &str, expected_owner_hex: &str, secret: &str) -> Result<String, (i32, String)> {
    let owner = Keys::parse(secret.trim()).map_err(|_| (2, "invalid owner key".into()))?;
    let expected = PublicKey::from_hex(expected_owner_hex)
        .map_err(|_| (2, "invalid expected owner pubkey".into()))?;
    if owner.public_key() != expected {
        return Err((3, "owner key does not match resolved Buzz identity".into()));
    }
    let agent = PublicKey::from_hex(agent_hex)
        .map_err(|_| (2, "invalid agent pubkey".into()))?;
    nip_oa::compute_auth_tag(&owner, &agent, "")
        .map_err(|error| (2, format!("cannot sign owner attestation: {error}")))
}
```
Add `#[cfg(test)]` cases that call `run`, parse the returned tag with
`nip_oa::verify_auth_tag`, assert the recovered owner is
`79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798`,
and assert the mismatch path returns code `3`.

`main` must require exactly two public arguments, read at most 512 bytes from stdin, call `run`, print only the tag on success, and print only the sanitized message on failure. Never include `secret`, `Debug` output of `Keys`, or stdin bytes in errors.

In `patches/buzz/Dockerfile`, after `COPY --exclude=opc . .` in the builder stage:

```dockerfile
COPY opc/opc-nip-oa-sign.rs crates/buzz-sdk/examples/opc_nip_oa_sign.rs
RUN cargo test --release --locked -p buzz-sdk --example opc_nip_oa_sign \
    && cargo build --release --locked -p buzz-sdk --example opc_nip_oa_sign
```

Copy and strip `target/release/examples/opc_nip_oa_sign` into `/usr/local/bin/opc-nip-oa-sign` in `opc-relay` so both the relay and frontdoor image targets expose the same helper.

- [ ] **Step 4: Run the signer test and verify GREEN**

Run:

```bash
scripts/prepare.sh
sh scripts/test-buzz-owner-signer.sh
```

Expected: PASS; valid tag shape, mismatch exit `3`, and no secret in captured output.

- [ ] **Step 5: Commit the signer**

```bash
git add patches/buzz/opc-nip-oa-sign.rs patches/buzz/Dockerfile scripts/test-buzz-owner-signer.sh
git commit -m "feat: add isolated Buzz owner attestation signer"
```

---

### Task 2: Account-Name Owner Setup Command

**Files:**
- Create: `scripts/set-buzz-agent-owner.sh`
- Create: `scripts/test-set-buzz-agent-owner.sh`
- Modify: `.env.example`
- Modify: `docker-compose.yml:266-280` (retain and test the current `BUZZ_AUTH_TAG` pass-through)

**Interfaces:**
- CLI: `scripts/set-buzz-agent-owner.sh <display-name-or-64-hex-pubkey>`.
- Reads: running `buzz-db`, `/keys/agent.pub` through a disposable Buzz container, `.env`, and the host key file.
- Writes atomically: `BUZZ_ACP_AGENT_OWNER`, `BUZZ_AUTH_TAG`, `BUZZ_OWNER_KEY_FILE` in `.env`.
- Invokes: Task 1 helper through `docker run --rm -i --network none` and then `docker compose up -d --no-deps --force-recreate frontdoor`.

- [ ] **Step 1: Write the failing host-script integration test**

Create `scripts/test-set-buzz-agent-owner.sh`. It must use a temporary directory containing:

- a copied `.env` fixture;
- a mode `0600` owner-key fixture;
- a fake `docker` executable prepended to `PATH`.

The fake Docker executable returns deterministic values for:

```text
docker compose exec -T buzz-db psql ...  -> one tab-separated human row
docker compose run --rm --no-deps ...    -> the fixed agent pubkey
docker image inspect ...                  -> success
docker run --rm -i --network none ...     -> a fixed valid public auth tag
docker compose up ... frontdoor           -> record invocation
docker compose logs ... frontdoor         -> owner resolved from BUZZ_AUTH_TAG
docker compose exec -T buzz-db psql ...   -> verification rows for mapping/kind 0/kind 10100
```

Run the production script with `OPC_ENV_FILE` pointing at the fixture. Assert:

```sh
assert_line 'BUZZ_ACP_AGENT_OWNER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
assert_line 'BUZZ_AUTH_TAG=["auth","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","","cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"]'
assert_line "BUZZ_OWNER_KEY_FILE=$key_file"
assert_count 1 '^BUZZ_AUTH_TAG='
assert_called 'compose up -d --no-deps --force-recreate frontdoor'
```

Add separate cases for zero matches, two matches, selected identity with non-null owner, key mode `0644`, signer mismatch exit `3`, and pre-existing different `BUZZ_ACP_AGENT_OWNER`. Each failure must leave the fixture `.env` byte-identical to its pre-run checksum.

- [ ] **Step 2: Run the host-script test and verify RED**

Run:

```bash
sh scripts/test-set-buzz-agent-owner.sh
```

Expected: FAIL because `scripts/set-buzz-agent-owner.sh` does not exist.

- [ ] **Step 3: Implement strict identity and key validation**

Implement the script in POSIX shell with `set -eu`. Support `OPC_ENV_FILE` only as a test/operator override, defaulting to `<repo>/.env`. Validate input as follows:

```sql
SELECT encode(pubkey, 'hex'), display_name,
       CASE WHEN agent_owner_pubkey IS NULL THEN 'human' ELSE 'agent' END
FROM users
WHERE deactivated_at IS NULL
  AND (
    lower(display_name) = lower(:selector)
    OR encode(pubkey, 'hex') = lower(:selector)
  )
ORDER BY encode(pubkey, 'hex');
```

Pass the selector through psql `--set=selector=...` and SQL literal quoting supported by psql variables; never interpolate raw selector text into SQL. Require exactly one row and classification `human`.

Resolve the key path from `BUZZ_OWNER_KEY_FILE` in the selected env file. If absent and stdin is a TTY, prompt for the path; otherwise fail with an instruction. Resolve it with `realpath`, require a regular file owned by `id -u`, and reject any permission bits matching group/other (`stat -c %a`).

Read the agent pubkey from `/keys/agent.pub` without exposing the agent nsec. Run the Task 1 helper with key contents on stdin. Parse the public tag with `jq`, requiring owner equals the resolved pubkey and conditions equals the empty string.

- [ ] **Step 4: Implement atomic env update and runtime verification**

Write a temporary file in the same directory as `.env`, preserve all unrelated lines and comments, replace all existing instances of the three managed keys with one canonical block, `chmod` it to the original mode, then `mv` atomically.

Before replacement, reject a non-empty existing `BUZZ_ACP_AGENT_OWNER` that differs from the selected owner. `BUZZ_AUTH_TAG` may be replaced only after the helper verifies the new tag for that same owner and current agent.

After recreate, verify:

```text
frontdoor log contains owner resolved from BUZZ_AUTH_TAG: <owner>
users.agent_owner_pubkey for Hermes equals <owner>
latest Hermes kind 0 has the same auth tag
latest Hermes kind 10100 has the same auth tag
```

Each query is bounded and fails loudly with the failed boundary. Do not claim Desktop activity can be verified from the host script because kind 24200 is ephemeral and Desktop-local ingestion is the final user-visible check.

- [ ] **Step 5: Document only the deploy inputs in `.env.example`**

Add:

```dotenv
# Public NIP-OA owner attestation generated by:
#   scripts/set-buzz-agent-owner.sh <display-name-or-pubkey>
BUZZ_ACP_AGENT_OWNER=
BUZZ_AUTH_TAG=
# Host-only path to the owner's pkey file; never passed into Compose.
BUZZ_OWNER_KEY_FILE=
```

Keep `docker-compose.yml` passing only `BUZZ_ACP_AGENT_OWNER` and `BUZZ_AUTH_TAG` to frontdoor. Add a test assertion using `docker compose config --format json` that `BUZZ_OWNER_KEY_FILE` is absent from every service environment.

- [ ] **Step 6: Run tests and verify GREEN**

Run:

```bash
sh scripts/test-set-buzz-agent-owner.sh
docker compose config --format json | jq -e \
  '.services.frontdoor.environment.BUZZ_AUTH_TAG != null and
   ([.services[].environment.BUZZ_OWNER_KEY_FILE?] | all(. == null))'
```

Expected: host-script cases PASS and Compose assertion returns `true`.

- [ ] **Step 7: Commit the owner setup command**

```bash
git add scripts/set-buzz-agent-owner.sh scripts/test-set-buzz-agent-owner.sh .env.example docker-compose.yml
git commit -m "feat: configure Buzz agent owner by account name"
```

---

### Task 3: Attested Agent Discovery Reconciliation

**Files:**
- Modify: `patches/buzz/opc-register-agent.sh:39-57`
- Create: `scripts/test-buzz-agent-registration.sh`

**Interfaces:**
- Consumes: `BUZZ_AUTH_TAG` inherited by the registration process and Buzz CLI.
- Produces: replaceable Hermes kind 0 metadata and kind 10100 metadata, both carrying the same valid NIP-OA auth tag.
- Retry invariant: kind 0 and kind 10100 each track independent success state; one success must not hide retries for the other.

- [ ] **Step 1: Write the failing registration behavior test**

Create `scripts/test-buzz-agent-registration.sh` with fake `curl`, `buzz`, `jq`, and `sleep` executables on `PATH`. The fake `buzz` records every argv vector. Make fake `sleep` exit with code `99` after the first loop so the production infinite reconciler completes one iteration under test.

Run `patches/buzz/opc-register-agent.sh` with fixture key files and assert the calls contain both:

```text
users set-profile --name hermes --about OPC front-door agent (hermes + opencode go)
channels set-add-policy --policy anyone
```

Add a retry case where kind 10100 fails once while kind 0 succeeds. On the next loop, assert kind 0 is not republished and kind 10100 is retried.

- [ ] **Step 2: Run the registration test and verify RED**

Run:

```bash
sh scripts/test-buzz-agent-registration.sh
```

Expected: FAIL because the current reconciler never calls `channels set-add-policy --policy anyone`.

- [ ] **Step 3: Implement independent kind 0 and kind 10100 reconciliation**

Replace `profile_ok` with two state flags and two functions:

```sh
metadata_ok=0
directory_ok=0

publish_metadata() {
    if buzz --relay "$RELAY_API" --private-key "$AGENT_NSEC" users set-profile \
        --name hermes --about 'OPC front-door agent (hermes + opencode go)' \
        >/dev/null 2>&1; then
        metadata_ok=1
        log "kind 0 profile published"
    else
        log "kind 0 profile publish failed — will retry"
    fi
}

publish_directory() {
    if buzz --relay "$RELAY_API" --private-key "$AGENT_NSEC" \
        channels set-add-policy --policy anyone >/dev/null 2>&1; then
        directory_ok=1
        log "kind 10100 agent directory profile published"
    else
        log "kind 10100 agent directory publish failed — will retry"
    fi
}
```

Call both once after readiness, then retry only the failed function in the loop. Do not manually construct auth tags: the CLI must inject the ambient verified `BUZZ_AUTH_TAG` into both events.

- [ ] **Step 4: Run the registration test and verify GREEN**

Run:

```bash
sh scripts/test-buzz-agent-registration.sh
```

Expected: PASS for initial dual publication and independent retry behavior.

- [ ] **Step 5: Run the actual image and connectivity verification**

Run:

```bash
scripts/prepare.sh
docker compose up -d --build --force-recreate frontdoor
scripts/test-connectivity.sh
```

Then verify the deployed ownership surfaces:

```bash
AGENT_PK="$(docker compose run --rm --no-deps buzz-bootstrap cat /keys/agent.pub)"
docker compose logs --since=5m --no-color frontdoor
docker compose exec -T buzz-db psql -U buzz -d buzz -P pager=off -x -c \
  "select kind, created_at, tags from events where pubkey=decode('$AGENT_PK','hex') and kind in (0,10100) order by kind"
```

Do not depend on any host Docker volume path; obtain the agent pubkey through `docker compose run --rm --no-deps buzz-bootstrap cat /keys/agent.pub` and bind it into the query. Expected: connectivity test passes; frontdoor resolves owner from `BUZZ_AUTH_TAG`; both latest events contain the same `auth` tag.

- [ ] **Step 6: Commit registration reconciliation**

```bash
git add patches/buzz/opc-register-agent.sh scripts/test-buzz-agent-registration.sh
git commit -m "fix: reconcile attested Buzz agent discovery"
```

---

### Task 4: End-to-End Owner Bootstrap Smoke Test

**Files:**
- Modify: `scripts/test-connectivity.sh` only if it already has a Buzz ownership section suitable for non-secret public checks; otherwise leave it unchanged.
- Test: deployed services and Buzz Desktop.

**Interfaces:**
- Consumes: completed Tasks 1-3 and the current noah owner configuration.
- Produces: evidence that fresh deployment reconstructs server and Desktop-visible ownership without reading the pkey again.

- [ ] **Step 1: Live-run the real operator command once**

Run:

```bash
scripts/set-buzz-agent-owner.sh noah
```

This exercises the exact command the user runs in daily operation. It reads the authorized owner key file (interactively resolved or from `BUZZ_OWNER_KEY_FILE`), writes the public attestation, and recreates frontdoor. Confirm the script reports the owner resolved from `BUZZ_AUTH_TAG` and the four ownership surfaces verify. Idempotent: the same owner key produces the same deterministic signature, so re-running is safe.

- [ ] **Step 2: Record the public state and make the pkey unavailable to deployment**

Confirm `.env` contains non-empty `BUZZ_AUTH_TAG`. Do not delete the pkey. Temporarily point `BUZZ_OWNER_KEY_FILE` at a nonexistent path only for the smoke command's environment, proving normal deployment does not read it.

- [ ] **Step 3: Recreate the ownership-dependent services without invoking the setup script**

Run:

```bash
BUZZ_OWNER_KEY_FILE=/nonexistent docker compose up -d --build --force-recreate buzz frontdoor
```

Expected: services start because Compose does not consume `BUZZ_OWNER_KEY_FILE`.

- [ ] **Step 4: Verify server-side reconstruction**

Run the exact public checks from Task 2:

- frontdoor resolved owner from `BUZZ_AUTH_TAG`;
- Hermes DB mapping equals noah;
- latest kind 0 has the noah auth tag;
- latest kind 10100 has the noah auth tag;
- relay metrics increase `buzz_events_received_total{kind="24200"}` during a new turn without an auth rejection.

- [ ] **Step 5: Verify the actual Desktop surface**

In Buzz Desktop, create a new Hermes turn that uses a tool. Confirm:

- profile displays `managed by you`, not `owner unavailable`;
- working state appears during execution;
- ACP activity shows live tool/session entries for the new turn.

Old turns are not an acceptance criterion because kind 24200 frames are ephemeral.

- [ ] **Step 6: Run final focused checks**

Run:

```bash
sh scripts/test-buzz-owner-signer.sh
sh scripts/test-set-buzz-agent-owner.sh
sh scripts/test-buzz-agent-registration.sh
scripts/prepare.sh
scripts/test-connectivity.sh
docker compose config --quiet
```

Expected: every command exits `0`; no warnings identify missing ownership inputs or failed profile publication.

- [ ] **Step 7: Commit any connectivity assertion added in this task**

If `scripts/test-connectivity.sh` changed:

```bash
git add scripts/test-connectivity.sh
git commit -m "test: verify Buzz owner bootstrap connectivity"
```

If no permanent connectivity assertion was appropriate, do not create an empty commit.
