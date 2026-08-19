# Buzz Agent Owner Bootstrap Design

## Problem

Buzz Desktop showed Hermes as working but displayed no ACP activity. Three independent facts are required for owner-scoped observer ingestion:

1. The relay must authorize Hermes observer frames against `users.agent_owner_pubkey`.
2. Hermes kind 0 metadata must carry a valid NIP-OA `auth` tag so Desktop can verify the owner.
3. Hermes must publish kind 10100 agent metadata so `useRelayAgentsQuery()` includes it in the observer ingestion set.

The deployment previously supplied only `BUZZ_ACP_AGENT_OWNER`. That selected the observer encryption recipient, but did not create a cryptographic owner attestation or an agent-directory record. A direct SQL update fixed relay authorization only; Desktop still showed `owner unavailable`. Adding the NIP-OA tag changed the profile to `managed by you`; adding kind 10100 restored ACP activity.

## Decision

NIP-OA is the single ownership truth. Do not maintain a separate SQL owner bootstrap.

Add an operator command:

```bash
scripts/set-buzz-agent-owner.sh <display-name-or-64-hex-pubkey>
```

The command resolves one Buzz human identity, obtains the owner's pkey from a local file, verifies that the pkey derives the resolved public key, signs an unrestricted NIP-OA tag for the existing front-door agent pubkey, stores only the public attestation in `.env`, and recreates frontdoor.

`BUZZ_AUTH_TAG` is then sufficient for every later deployment. The relay verifies it and materializes `users.agent_owner_pubkey`; the frontdoor registration loop republishes the attested kind 0 and kind 10100 records. `docker compose down -v` therefore does not require the owner pkey again.

## Operator Interface

The positional argument is either:

- an exact, case-insensitive Buzz `display_name`; or
- a canonical 64-character hexadecimal public key.

Name resolution must return exactly one active human identity. Missing or ambiguous names fail without changing `.env` or the stack. An identity already marked as an agent is rejected.

The pkey file path is resolved in this order:

1. host-only `.env` value `BUZZ_OWNER_KEY_FILE`;
2. an interactive prompt for a local file path.

The script never accepts the pkey as a command-line argument. This keeps it out of shell history and process listings. The file must be a regular file owned by the invoking user with no group/other permissions. Its content may be 64-hex or nsec as supported by the signing helper. The script never prints, copies, or persists the pkey.

After the first successful run, `.env` retains `BUZZ_OWNER_KEY_FILE` for operator convenience and `BUZZ_AUTH_TAG` for deployment. The key path is not passed to Compose services. Routine agent-assisted operation therefore needs only the account name.

## Components

### Signing helper

Build a small OPC helper from the existing `buzz_sdk::nip_oa::compute_auth_tag`
implementation. The helper is baked into the Buzz image and run through an
isolated `docker run --rm -i --network none` process: it reads the owner secret
from standard input, accepts the agent public key as an argument, verifies the
derived owner pubkey expected by the script, and writes only the JSON auth tag
to standard output. Error messages must not contain secret material. No host
toolchain beyond Docker is required.

### Owner setup script

`scripts/set-buzz-agent-owner.sh` performs a staged update:

1. validate arguments and repository prerequisites;
2. resolve the owner through the running Buzz database;
3. validate the key file and derive/sign the attestation;
4. verify the generated tag against the front-door agent pubkey;
5. atomically update `BUZZ_ACP_AGENT_OWNER`, `BUZZ_AUTH_TAG`, and `BUZZ_OWNER_KEY_FILE` in `.env`;
6. recreate frontdoor;
7. verify the frontdoor resolved the owner from `BUZZ_AUTH_TAG`;
8. verify latest Hermes kind 0 and kind 10100 events contain the same valid `auth` tag.

A failure before step 5 changes nothing. A failure after step 5 reports the exact failed boundary and preserves the valid public attestation for retry.

### Compose wiring

Frontdoor receives `BUZZ_AUTH_TAG` from `.env`. `BUZZ_OWNER_KEY_FILE` is intentionally absent from the container environment and mounts.

`BUZZ_ACP_AGENT_OWNER` remains as an explicit recipient/debug value, but `buzz-acp` resolves and verifies the owner from `BUZZ_AUTH_TAG` first. A mismatch between the two configured public owners is an error in the setup script.

### Frontdoor registration

`opc-register-agent.sh` reconciles both agent discovery surfaces on every boot:

- kind 0 via `buzz users set-profile`, preserving the ambient NIP-OA tag;
- kind 10100 via `buzz channels set-add-policy --policy anyone`, also preserving the tag.

Both publications are idempotent replaceable events. Reconciliation happens after relay readiness. A publication failure remains retryable in the existing registration loop and is logged separately for kind 0 and kind 10100.

## Security Invariants

- The owner pkey never enters `.env`, Compose configuration, mounts, command-line arguments, logs, or the database. It exists only in its host file and the standard input/process memory of a network-isolated, disposable signing container.
- Only a valid NIP-OA signature establishes ownership. Display name lookup alone grants no authority.
- The generated tag must verify for the exact current front-door agent pubkey and resolved owner pubkey.
- Existing ownership for a different owner fails loudly; the script does not silently rotate ownership.
- The public auth tag is safe to persist and publish.
- Upstream submodules remain unmodified; all image changes live under `patches/`.

## Verification

Automated checks cover:

- exact name and public-key resolution;
- missing and ambiguous names;
- rejection of an agent as owner;
- insecure key-file permissions;
- owner pkey/public-key mismatch;
- atomic `.env` insertion and replacement without duplicate keys;
- Compose passing `BUZZ_AUTH_TAG` but not `BUZZ_OWNER_KEY_FILE`;
- registration invoking both kind 0 and kind 10100 publication paths with retry behavior.

The deployment smoke test verifies:

1. frontdoor logs `owner resolved from BUZZ_AUTH_TAG`;
2. DB owner mapping equals the resolved owner;
3. latest Hermes kind 0 contains the valid tag;
4. latest Hermes kind 10100 contains the valid tag;
5. a new Buzz turn emits accepted kind 24200 frames.

Final Desktop confirmation is behavioral: Hermes shows `managed by you`, and a new turn displays ACP activity. Ephemeral frames from earlier turns are not expected to backfill.
