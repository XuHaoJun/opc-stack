# OpenAI-Compatible Environment Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the OPC stack's `OPENCODE_*` provider environment contract with canonical `OPENAI_API_KEY`, `OPENAI_BASE_URL`, and `OPENAI_MODEL` names, then migrate the running stack without deleting volumes.

**Architecture:** The host `.env` and Compose file become the only deployment-level source for the three canonical names. Buzz/Hermes entrypoints pass the key and base URL to Hermes at runtime and use the model/base URL to seed editable Hermes and omp configuration. TencentDB receives the same canonical values through its existing `TDAI_LLM_*` adapter variables; Buzz keeps its explicit `BUZZ_AGENT_MODEL` override.

**Tech Stack:** Docker Compose interpolation, POSIX shell entrypoints, Bash verification scripts, Hermes YAML configuration, Markdown operational documentation.

## Global Constraints

- `OPENAI_API_KEY` is the shared provider key; remove `OPENCODE_API_KEY`.
- `OPENAI_BASE_URL` defaults to `https://opencode.ai/zen/go/v1`.
- `OPENAI_MODEL` defaults to `deepseek-v4-flash` and is an OPC seed convention, not an upstream SDK variable.
- Keep `BUZZ_AGENT_MODEL` as the front-door-specific override with its current default `deepseek-v4-pro`.
- No `OPENCODE_*` compatibility fallback may silently control a service after the cutover.
- Do not edit `upstream/`; modify `patches/` and run `scripts/prepare.sh` before builds.
- Migrate the live `.env` in place and do not delete volumes or reset persistent service state.
- Do not add a migration script; perform the current-environment rename manually.
- Do not make a paid provider request for rename verification.

---

### Task 1: Establish the failing canonical-contract probe

**Files:**
- No committed file; use a temporary environment and rendered Compose output.

**Interfaces:**
- Consumes: current `.env` values and `docker compose config`.
- Produces: a red contract probe proving the current tree still exposes legacy names and does not wire the new canonical base/model values.

- [ ] **Step 1: Generate a temporary env with canonical test values**

Run this from the repository root. It copies the existing assignment lines so required Compose secrets remain available, then overrides only the provider contract with non-secret test values:

```bash
tmp_env="$(mktemp)"
python3 - "$tmp_env" <<'PY'
from pathlib import Path
import sys

source = Path(".env") if Path(".env").exists() else Path(".env.example")
lines = source.read_text().splitlines()
overrides = {
    "OPENAI_API_KEY": "contract-test-key",
    "OPENAI_BASE_URL": "https://contract.invalid/v1",
    "OPENAI_MODEL": "contract-test-model",
    "BUZZ_AGENT_MODEL": "contract-frontdoor-model",
}
seen = set()
out = []
for line in lines:
    if line and not line.lstrip().startswith("#") and "=" in line:
        key = line.split("=", 1)[0]
        if key in overrides:
            out.append(f"{key}={overrides[key]}")
            seen.add(key)
            continue
    out.append(line)
for key, value in overrides.items():
    if key not in seen:
        out.append(f"{key}={value}")
Path(sys.argv[1]).write_text("\n".join(out) + "\n")
PY
compose_config="$(mktemp)"
docker compose --env-file "$tmp_env" config > "$compose_config"
```

- [ ] **Step 2: Run the contract assertions and confirm RED**

```bash
python3 - "$compose_config" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
assert "OPENAI_BASE_URL: https://contract.invalid/v1" in text
assert "OPENAI_MODEL: contract-test-model" in text
assert "OPENAI_API_KEY: contract-test-key" in text
assert "OPENCODE_API_KEY" not in text
assert "OPENCODE_GO_BASE_URL" not in text
assert "OPENCODE_GO_MODEL" not in text
PY
```

Expected result before implementation: `AssertionError`, because Compose still reads `OPENCODE_GO_*` and emits legacy container variables. Remove the temporary files after the red result:

```bash
rm -f "$tmp_env" "$compose_config"
```

- [ ] **Step 3: Commit the red-contract evidence only in the task log**

Do not commit temporary files or add a migration script. The rendered assertion is the test-first contract for the source and wiring edits that follow.

---

### Task 2: Cut over the host and Compose environment contract

**Files:**
- Modify: `.env.example:5-35,125-133`
- Modify: `docker-compose.yml:175-177,289-307,369-379,434-444,509-513,677-685`

**Interfaces:**
- Consumes: the canonical names from the approved spec.
- Produces: Compose services that receive only canonical provider names, with `BUZZ_AGENT_MODEL` still selecting the front-door model.

- [ ] **Step 1: Rename the sample variables and comments**

In `.env.example`, change the quickstart and provider section to:

```dotenv
#   2. Fill in OPENAI_API_KEY (OpenAI-compatible provider; one key for the whole stack)
# ── LLM provider: OpenAI-compatible endpoint (OpenCode Go default) ──
# OpenAI-compatible endpoint: https://opencode.ai/zen/go/v1
# One key powers Hermes (front door + gateway), omp, and TencentDB memory.
OPENAI_API_KEY=
OPENAI_BASE_URL=https://opencode.ai/zen/go/v1
OPENAI_MODEL=deepseek-v4-flash

# ── Other LLM provider keys (optional; leave empty if using the OpenAI-compatible endpoint) ──
```

Remove the duplicate optional `OPENAI_API_KEY=` line from the other-provider list. Update the TencentDB comments at the LLM section to say its defaults follow `OPENAI_*`, and replace the old fallback names in those comments.

- [ ] **Step 2: Replace Buzz service interpolation**

In the `buzz` service, remove `OPENCODE_API_KEY` and keep only:

```yaml
OPENAI_API_KEY: ${OPENAI_API_KEY:-}
```

- [ ] **Step 3: Replace front-door interpolation without changing its model choice**

In the `frontdoor` service, replace the old key/base/model entries with:

```yaml
OPENAI_API_KEY: ${OPENAI_API_KEY:-}
OPENAI_BASE_URL: ${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}
OPENAI_MODEL: ${BUZZ_AGENT_MODEL:-deepseek-v4-pro}
```

Do not expose `OPENCODE_API_KEY`, `OPENCODE_GO_BASE_URL`, or `OPENCODE_GO_MODEL` to this container.

- [ ] **Step 4: Replace gateway and dashboard interpolation**

In both `hermes` and `hermes-dashboard`, use:

```yaml
OPENAI_API_KEY: ${OPENAI_API_KEY:-}
OPENAI_BASE_URL: ${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}
OPENAI_MODEL: ${OPENAI_MODEL:-deepseek-v4-flash}
```

Remove their legacy variables entirely.

- [ ] **Step 5: Pass the canonical contract to Paperclip tooling**

In the `paperclip` service, retain `OPENAI_API_KEY` and add the matching provider-neutral values:

```yaml
OPENAI_API_KEY: ${OPENAI_API_KEY:-}
OPENAI_BASE_URL: ${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}
OPENAI_MODEL: ${OPENAI_MODEL:-deepseek-v4-flash}
```

Remove `OPENCODE_API_KEY` and do not add any legacy aliases.

- [ ] **Step 6: Replace TencentDB fallback precedence**

Use the canonical stack values as the existing `TDAI_LLM_*` fallbacks:

```yaml
TDAI_LLM_API_KEY: ${OPENAI_API_KEY:-${TENCENTDB_LLM_API_KEY:-}}
TDAI_LLM_BASE_URL: ${TENCENTDB_LLM_BASE_URL:-${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}}
TDAI_LLM_MODEL: ${TENCENTDB_LLM_MODEL:-${OPENAI_MODEL:-deepseek-v4-flash}}
```

- [ ] **Step 7: Re-run the contract probe and confirm GREEN**

Repeat Task 1's temporary render and assertions. Expected result: all assertions pass, including the absence of the three legacy names from the rendered Compose model.

- [ ] **Step 8: Commit the Compose contract cutover**

```bash
git add .env.example docker-compose.yml
git commit -m "refactor: use OpenAI-compatible compose variables"
```

---

### Task 3: Update entrypoints and omp seed configuration

**Files:**
- Modify: `patches/buzz/frontdoor-entrypoint.sh:111-119,186-198,230-232`
- Modify: `patches/hermes/hermes-entrypoint.sh:118-144`
- Modify: `patches/buzz/nix-seed.sh:49-65`
- Modify: `patches/hermes/nix-seed.sh:49-65`
- Modify: `patches/paperclip/nix-seed.sh:49-65`

**Interfaces:**
- Consumes: `OPENAI_API_KEY`, `OPENAI_BASE_URL`, and `OPENAI_MODEL` from Task 2; front door receives `OPENAI_MODEL` from `BUZZ_AGENT_MODEL` in Compose.
- Produces: seeded Hermes/omp configuration and runtime exports with no legacy variable reads.

- [ ] **Step 1: Write the entrypoint contract checks before editing**

Run the following against the current patch sources and confirm it fails because the old names are still present:

```bash
python3 - <<'PY'
from pathlib import Path
paths = [
    Path("patches/buzz/frontdoor-entrypoint.sh"),
    Path("patches/hermes/hermes-entrypoint.sh"),
    Path("patches/buzz/nix-seed.sh"),
    Path("patches/hermes/nix-seed.sh"),
    Path("patches/paperclip/nix-seed.sh"),
]
text = "\n".join(path.read_text() for path in paths)
for name in ("OPENCODE_API_KEY", "OPENCODE_GO_BASE_URL", "OPENCODE_GO_MODEL"):
    assert name not in text, name
PY
```

- [ ] **Step 2: Switch omp seed model reads**

In all three `nix-seed.sh` copies, replace both `${OPENCODE_GO_MODEL:-deepseek-v4-flash}` expansions with `${OPENAI_MODEL:-deepseek-v4-flash}`. Keep the serialized omp provider slug `opencode-go/`; it identifies the installed omp provider and is not an environment variable name.

- [ ] **Step 3: Switch front-door and Hermes YAML seed reads**

In both entrypoints, replace the model seed and log expansion with `${OPENAI_MODEL:-deepseek-v4-flash}` and the base URL expansion with `${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}`. Keep the existing exact-value legacy config reconciliation behavior; only the variable source changes.

- [ ] **Step 4: Switch runtime key/base-url export**

In both entrypoints, replace the old fallback expressions with canonical defaults:

```sh
: "${OPENAI_API_KEY:=}"
: "${OPENAI_BASE_URL:=https://opencode.ai/zen/go/v1}"
export OPENAI_API_KEY OPENAI_BASE_URL
```

Do not recreate an `OPENCODE_API_KEY` or `OPENCODE_GO_*` alias.

- [ ] **Step 5: Run the entrypoint contract checks and shell syntax checks**

```bash
python3 - <<'PY'
from pathlib import Path
paths = [
    Path("patches/buzz/frontdoor-entrypoint.sh"),
    Path("patches/hermes/hermes-entrypoint.sh"),
    Path("patches/buzz/nix-seed.sh"),
    Path("patches/hermes/nix-seed.sh"),
    Path("patches/paperclip/nix-seed.sh"),
]
text = "\n".join(path.read_text() for path in paths)
for name in ("OPENCODE_API_KEY", "OPENCODE_GO_BASE_URL", "OPENCODE_GO_MODEL"):
    assert name not in text, name
PY
bash -n patches/buzz/frontdoor-entrypoint.sh
bash -n patches/hermes/hermes-entrypoint.sh
bash -n patches/buzz/nix-seed.sh
bash -n patches/hermes/nix-seed.sh
bash -n patches/paperclip/nix-seed.sh
```

- [ ] **Step 6: Commit the patch-source cutover**

```bash
git add patches/buzz/frontdoor-entrypoint.sh patches/buzz/nix-seed.sh \
  patches/hermes/hermes-entrypoint.sh patches/hermes/nix-seed.sh \
  patches/paperclip/nix-seed.sh
git commit -m "refactor: seed Hermes and omp from OpenAI env"
```

---

### Task 4: Update operational documentation and setup guidance

**Files:**
- Modify: `README.md:16`
- Modify: `SETUP.md:18-20,87-102`
- Modify: `AGENTS.md:13,123`
- Modify: `scripts/setup.sh:14-19`
- Modify: `docs/env-vars-seed-vs-runtime.md:19-21,53-60`
- Modify: `.claude/skills/upgrade-opc-stack/references/risk-checklist.md:102-105`

**Interfaces:**
- Consumes: the canonical names and precedence from Tasks 2–3.
- Produces: operator-facing instructions that never tell a new deployment to set removed names.

- [ ] **Step 1: Write the documentation scan before editing**

```bash
python3 - <<'PY'
from pathlib import Path
paths = [
    Path("README.md"), Path("SETUP.md"), Path("AGENTS.md"),
    Path("scripts/setup.sh"), Path("docs/env-vars-seed-vs-runtime.md"),
    Path(".claude/skills/upgrade-opc-stack/references/risk-checklist.md"),
]
text = "\n".join(path.read_text() for path in paths)
for name in ("OPENCODE_API_KEY", "OPENCODE_GO_BASE_URL", "OPENCODE_GO_MODEL"):
    assert name not in text, name
PY
```

Expected result before edits: failure naming the first legacy variable.

- [ ] **Step 2: Update quickstart and provider descriptions**

Use `OPENAI_API_KEY` in README, SETUP, and `scripts/setup.sh`. Describe OpenCode Go as the default OpenAI-compatible endpoint, and document `OPENAI_BASE_URL` / `OPENAI_MODEL` as the local stack overrides. State that Hermes custom provider runtime uses `OPENAI_API_KEY` and `OPENAI_BASE_URL`, while model selection is persisted in `config.yaml`.

- [ ] **Step 3: Update runtime/seed classification and upgrade checklist**

Rename the table entries and config-trap heading in `docs/env-vars-seed-vs-runtime.md`. The trap must explain `OPENAI_BASE_URL` and `OPENAI_MODEL`, including that existing editable configs may need manual adjustment. In the upgrade checklist, replace the old fallback-chain description with the single canonical `OPENAI_API_KEY` contract.

- [ ] **Step 4: Update AGENTS.md operational invariants**

Change the stack LLM rule and the normal omp path to `OPENAI_API_KEY`. Do not weaken the existing warning that credentials are copied into runtime homes; only the variable name changes.

- [ ] **Step 5: Re-run the documentation scan and commit**

```bash
python3 - <<'PY'
from pathlib import Path
paths = [
    Path("README.md"), Path("SETUP.md"), Path("AGENTS.md"),
    Path("scripts/setup.sh"), Path("docs/env-vars-seed-vs-runtime.md"),
    Path(".claude/skills/upgrade-opc-stack/references/risk-checklist.md"),
]
text = "\n".join(path.read_text() for path in paths)
for name in ("OPENCODE_API_KEY", "OPENCODE_GO_BASE_URL", "OPENCODE_GO_MODEL"):
    assert name not in text, name
PY
bash -n scripts/setup.sh
git add README.md SETUP.md AGENTS.md scripts/setup.sh \
  docs/env-vars-seed-vs-runtime.md \
  .claude/skills/upgrade-opc-stack/references/risk-checklist.md
git commit -m "docs: document OpenAI-compatible env contract"
```

---

### Task 5: Migrate the live `.env` and reconcile editable config

**Files:**
- Modify: `.env` (ignored live deployment file; do not commit)
- Inspect: `/opt/data/config.yaml` in `hermes` and `frontdoor` containers

**Interfaces:**
- Consumes: the canonical Compose contract and current live values.
- Produces: a running deployment with the same effective key, endpoint, and model, under the new names and without volume deletion.

- [ ] **Step 1: Confirm the live values without printing secrets**

Use a short Python inspection that reports only presence and hashes for keys and prints non-secret endpoint/model values:

```bash
python3 - <<'PY'
from pathlib import Path
import hashlib
wanted = {"OPENCODE_API_KEY", "OPENAI_API_KEY", "OPENCODE_GO_BASE_URL", "OPENCODE_GO_MODEL", "OPENAI_BASE_URL", "OPENAI_MODEL"}
values = {}
for line in Path(".env").read_text().splitlines():
    if line and not line.lstrip().startswith("#") and "=" in line:
        key, value = line.split("=", 1)
        if key in wanted:
            values[key] = value
for key in sorted(values):
    value = values[key]
    if key.endswith("API_KEY"):
        shown = f"set sha256={hashlib.sha256(value.encode()).hexdigest()[:12]}" if value else "empty"
    else:
        shown = value or "empty"
    print(f"{key}: {shown}")
PY
```

Expected current state: the old key/base/model are set, and `OPENAI_API_KEY` is empty.

- [ ] **Step 2: Rename the three live assignments manually**

Edit `.env` in place. Keep each existing right-hand value byte-for-byte and
change only the assignment keys:

- Rename the `OPENCODE_API_KEY` assignment key to `OPENAI_API_KEY`.
- Rename the `OPENCODE_GO_BASE_URL` assignment key to `OPENAI_BASE_URL`.
- Rename the `OPENCODE_GO_MODEL` assignment key to `OPENAI_MODEL`.

If `.env` already contains an empty `OPENAI_API_KEY=` assignment, remove that
duplicate before or while applying the key rename.


- [ ] **Step 3: Inspect existing editable Hermes configuration before restart**

```bash
docker compose exec -T hermes sh -c 'sed -n "/^model:/,/^[^ ]/p" /opt/data/config.yaml'
docker compose exec -T frontdoor sh -c 'sed -n "/^model:/,/^[^ ]/p" /opt/data/config.yaml'
```

Compare only `base_url` and `default` with the migrated `.env`. If either differs, update those two YAML values manually in the corresponding container, changing no unrelated dashboard edits. If they already match, leave the files untouched.

- [ ] **Step 4: Apply patches and recreate affected services without deleting volumes**

```bash
scripts/prepare.sh
docker compose up -d --build buzz frontdoor hermes hermes-dashboard paperclip tencentdb-core
```

Do not run `docker compose down -v`. The named volumes and databases must survive the migration.

- [ ] **Step 5: Verify container-level canonical environment without exposing values**

```bash
docker compose exec -T frontdoor sh -c '
  test -n "${OPENAI_BASE_URL:-}" &&
  test -n "${OPENAI_MODEL:-}" &&
  test -z "${OPENCODE_API_KEY+x}" &&
  test -z "${OPENCODE_GO_BASE_URL+x}" &&
  test -z "${OPENCODE_GO_MODEL+x}"
'
docker compose exec -T hermes sh -c '
  test -n "${OPENAI_BASE_URL:-}" &&
  test -n "${OPENAI_MODEL:-}" &&
  test -z "${OPENCODE_API_KEY+x}" &&
  test -z "${OPENCODE_GO_BASE_URL+x}" &&
  test -z "${OPENCODE_GO_MODEL+x}"
'
```

- [ ] **Step 6: Commit only tracked source changes**

```bash
git status --short
```

Confirm `.env` is ignored and no `upstream/` file is staged. Do not commit the live `.env`.

---

### Task 6: Run final repository and live-stack verification

**Files:**
- Inspect: all tracked local source files excluding `upstream/` and the intentionally historical design/spec text.

**Interfaces:**
- Consumes: all source, patch, documentation, and live migration changes.
- Produces: evidence that the canonical contract is complete and the stack remains healthy.

- [ ] **Step 1: Run the tracked-source legacy scan**

```bash
python3 - <<'PY'
from pathlib import Path
roots = [Path(".env.example"), Path("docker-compose.yml"), Path("README.md"), Path("SETUP.md"), Path("AGENTS.md"), Path("scripts"), Path("patches"), Path("docs/env-vars-seed-vs-runtime.md"), Path(".claude/skills/upgrade-opc-stack")]
legacy = ("OPENCODE_API_KEY", "OPENCODE_GO_BASE_URL", "OPENCODE_GO_MODEL")
found = []
for root in roots:
    files = [root] if root.is_file() else [p for p in root.rglob("*") if p.is_file()]
    for path in files:
        text = path.read_text(errors="replace")
        for name in legacy:
            if name in text:
                found.append(f"{path}: {name}")
assert not found, "\n".join(found)
PY
```

The approved design spec itself may mention legacy names as historical migration targets; it is intentionally outside this runtime-source scan.

- [ ] **Step 2: Render the final Compose model with canonical test values**

Repeat Task 1's temporary `docker compose config` assertions. Expected result: all canonical values are present, all three legacy names are absent, and the command exits 0.

- [ ] **Step 3: Run shell syntax checks**

```bash
bash -n scripts/setup.sh
bash -n patches/buzz/frontdoor-entrypoint.sh
bash -n patches/hermes/hermes-entrypoint.sh
bash -n patches/buzz/nix-seed.sh
bash -n patches/hermes/nix-seed.sh
bash -n patches/paperclip/nix-seed.sh
```

- [ ] **Step 4: Run the live connectivity smoke test**

```bash
scripts/test-connectivity.sh
```

Expected result: every container, one-shot bootstrap, published HTTP endpoint, and frontdoor-to-Buzz relay check reports `PASS`. This test intentionally does not call the LLM.

- [ ] **Step 5: Verify config values and git cleanliness**

```bash
docker compose exec -T hermes sh -c 'sed -n "/^model:/,/^[^ ]/p" /opt/data/config.yaml'
docker compose exec -T frontdoor sh -c 'sed -n "/^model:/,/^[^ ]/p" /opt/data/config.yaml'
git status --short
```

Confirm both configs contain the migrated endpoint/model, the live `.env` is not tracked, and no upstream submodule content was edited. Commit any remaining tracked source edits with:

```bash
git add .env.example docker-compose.yml patches README.md SETUP.md AGENTS.md scripts/setup.sh docs/env-vars-seed-vs-runtime.md .claude/skills/upgrade-opc-stack/references/risk-checklist.md
git commit -m "refactor: complete OpenAI-compatible env migration"
```
