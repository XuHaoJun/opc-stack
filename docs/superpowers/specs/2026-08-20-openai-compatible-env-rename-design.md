# OpenAI-Compatible Environment Naming Design

## Goal

Replace the stack's provider-specific `OPENCODE_*` environment contract with
provider-neutral names that match the OpenAI-compatible interface actually used
by Hermes and the other services.

## Canonical contract

- `OPENAI_API_KEY`: shared API key for Buzz, Hermes, omp, Paperclip tooling,
  and TencentDB memory. The old `OPENCODE_API_KEY` name is removed.
- `OPENAI_BASE_URL`: OpenAI-compatible API root. Default:
  `https://opencode.ai/zen/go/v1`.
- `OPENAI_MODEL`: stack model used when seeding Hermes and omp configuration.
  Default: `deepseek-v4-flash`.

`OPENAI_MODEL` is an OPC stack convention, not a variable read by the
upstream OpenAI SDK. Hermes uses `OPENAI_API_KEY` and `OPENAI_BASE_URL` at
runtime, while `config.yaml`'s model entry remains the runtime source of truth
for the model. The entrypoints use `OPENAI_MODEL` only when seeding or
reconciling that config. OpenCode Go remains a documented default endpoint, not
part of the environment variable names.

The existing `BUZZ_AGENT_MODEL` remains a Buzz front-door-specific override and
keeps its current default (`deepseek-v4-pro`). It is deliberately not folded
into the shared model variable because the front door has a separately
validated model choice.

## Affected surfaces

Update all local consumers and documentation:

- `.env.example` and `docker-compose.yml`.
- Buzz and Hermes entrypoint config seeding and runtime key/base-url export.
- Buzz, Hermes, and Paperclip omp seed scripts.
- TencentDB core key/base/model fallback wiring.
- `README.md`, `SETUP.md`, `AGENTS.md`, runtime env classification, and the
  upgrade risk checklist.

No upstream submodule files are edited. `patches/` remains the source of truth.
No compatibility fallback is kept: after the cutover, a stale `OPENCODE_*`
name must not silently control a service.

## Current-environment migration

The live `.env` currently has values for `OPENCODE_API_KEY`,
`OPENCODE_GO_BASE_URL`, and `OPENCODE_GO_MODEL`; `OPENAI_API_KEY` is empty.
Migrate those values in place, preserving their effective values, to the three
canonical names and remove the old assignments. Do not remove volumes or reset
persistent service state.

Recreate the services after the source and image changes. Before restarting,
inspect the existing Hermes/front-door `config.yaml` model and base URL. If
they differ from the migrated `.env`, update those two config fields manually;
do not delete the editable config or overwrite unrelated dashboard changes.

## Verification contract

- A repository-wide local-source scan finds no `OPENCODE_API_KEY`,
  `OPENCODE_GO_BASE_URL`, or `OPENCODE_GO_MODEL` references outside historical
  design/context text explicitly retained by policy.
- Compose rendering with a temporary env proves the canonical values reach
  frontdoor, Hermes, dashboard, Paperclip, and TencentDB with the expected
  precedence and no legacy variables.
- Shell syntax checks pass for modified entrypoints and seed scripts.
- The running stack is recreated without volume deletion; connectivity smoke
  tests pass.
- Existing Hermes/front-door config contains the migrated endpoint/model values
  and no runtime path depends on the removed names. No paid provider request is
  required for this rename verification.
