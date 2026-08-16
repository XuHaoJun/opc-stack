# OPC Stack — Setup Guide

Buzz (conversation) + Hermes (agent runtime) + Paperclip (work control plane)
+ TencentDB-Agent-Memory (agent memory), all in one docker compose stack.
Hermes Kanban is disabled on both Hermes surfaces (Paperclip is the canonical
work plane), matching docs/nodalis-prd-v10.md.

The repo is portable: `upstream/` holds the four projects as git submodules
pinned to release tags; `patches/` holds every local customization
(custom Dockerfiles, entrypoints, bootstrap scripts). Nothing else is
touched — upgrading is a tag checkout + rebuild.

## Quickstart (new machine)

```bash
git clone <this-repo-url> opc-stack && cd opc-stack
git submodule update --init --recursive
cp .env.example .env
# edit .env: fill in OPENCODE_API_KEY (OpenCode Go — one key for the stack),
#            set BUZZ_RELAY_URL to this machine's LAN IP for device access
scripts/setup.sh          # same as: submodule init + prepare + up -d --build
scripts/test-connectivity.sh
```

`scripts/setup.sh` is idempotent — safe to re-run any time. It applies the
patches (copies `patches/<proj>/` onto `upstream/<proj>/opc/`), builds all
images, and brings the stack up. `test-connectivity.sh` probes every
service endpoint and the frontdoor→relay link without ever calling an LLM.

> Note: after `docker compose down -v`, relay/agent keys, community,
> tencentdb admin, and paperclip bootstrap are all recreated automatically by
> the one-shot bootstrap containers. Fresh installs need no manual signing.

## Image prefix / project name

| `.env` var | default | purpose |
|---|---|---|
| `IMAGE_PREFIX` | `opc` | prefix of locally built images (`opc/buzz:local` …) |
| `COMPOSE_PROJECT_NAME` | `opc` | compose project name; prefixes named volumes. Change **before** first `up`; lets two stacks coexist on one host |

## Upgrading a component

**Recommended path: the `upgrade-opc-stack` skill** (`.claude/skills/upgrade-opc-stack/`).
It wraps `scripts/upgrade.sh` with a risk assessment, unconditional backup of
stateful volumes (`.claude/skills/upgrade-opc-stack/scripts/backup-volumes.sh`),
a user approval gate, post-upgrade verification, and an on-approval rollback
(`restore-volumes.sh`). Ask your agent to "upgrade <component> to <tag>" and it
runs the full flow.

The raw engine, for scripted/CI use:

- Verifies the tag exists on upstream (`git ls-remote --tags`), removes stale
  patched files from the submodule worktree, checks out the new tag, records
  the new submodule pointer, re-applies patches, then rebuilds + redeploys
  that component's services.
- ⚠ Patches were written against the pinned tag — a major upgrade may need
  patch edits. Review `git -C upstream/<proj> log --oneline <old>..<new>`
  before rebuilding if in doubt.
- Component → services mapping: `buzz` → buzz-keys/buzz/buzz-bootstrap/frontdoor ·
  `hermes` → hermes · `paperclip` → paperclip · `tencentdb` → tencentdb-core/
  bootstrap/hub/proxy.
- To see available tags: `git -C upstream/<proj> ls-remote --tags origin`.

## LLM provider: OpenCode Go (default)

The stack ships pre-configured for **OpenCode Go** (`https://opencode.ai/zen/go/v1`,
default model `deepseek-v4-flash`, override via `OPENCODE_GO_MODEL` in `.env`). Set
`OPENCODE_API_KEY` in `.env` and everything uses it:

| Project | Where the model/key is configured | UI-editable? |
|---|---|---|
| Hermes (gateway + front door) | config.yaml seeded to `provider: custom`, `base_url: opencode.ai/zen/go/v1`, `default: deepseek-v4-flash`; key via `OPENAI_API_KEY` (= your `OPENCODE_API_KEY`) | **Yes — dashboard http://localhost:9119 → config/model pages** |
| Paperclip | Agents use the Hermes Gateway adapter → model lives in Hermes | Agent adapter fields in the Paperclip UI |
| TencentDB memory | `TDAI_LLM_*` / `LLM_*` / proxy upstream — all default to OpenCode Go | Panel has ApiKeys + knowledge LLM-binding pages; core extraction follows env |
| Buzz | None needed | — |

If you prefer another provider, change it in the Hermes dashboard UI (or
override `OPENCODE_GO_BASE_URL` / `OPENCODE_GO_MODEL` in `.env` for a fresh
install). Any OpenAI-compatible endpoint works for every project above.

| Project | Repo | Tag |
|---|---|---|
| Buzz | block/buzz | desktop-v0.5.14 |
| Hermes | NousResearch/hermes-agent | v2026.8.13 (= v0.20.1) |
| Paperclip | paperclipai/paperclip | canary/v2026.722.1-canary.0 |
| TencentDB-Agent-Memory | TencentCloud/TencentDB-Agent-Memory | v2.0.0 (branch feat/server_team) |

## Setup pages (after `docker compose up -d`)

| Project | URL | What you do there |
|---|---|---|
| **Paperclip** | http://localhost:3100 | Auto-bootstrapped by the `paperclip-bootstrap` one-shot: first admin (log in with `PAPERCLIP_ADMIN_EMAIL` / `PAPERCLIP_ADMIN_PASSWORD` from `.env`), default company, the OMP executor agent, and the frontdoor API key (written to the keys volume — no manual step). Then, optionally, Agents → add a **Hermes Gateway** agent: `apiBaseUrl: http://hermes:8642`, `apiKey: <HERMES_API_SERVER_KEY from .env>`. |
| **Hermes dashboard** | http://localhost:9119 | Basic auth: `HERMES_DASHBOARD_USERNAME` / `HERMES_DASHBOARD_PASSWORD` from `.env`. Served by the `hermes-dashboard` container over the Buzz front door's hermes home — **Sessions** (Automation/All filter 才看得到 ACP session) 與 **Logs → AGENT** (live agent log, 含 `acp::thought` chain-of-thought, 由 frontdoor 的 RUST_LOG + tee 餵進 `/opt/data/logs/agent.log`)。Kanban disabled by config. 注意: 頁面右上「Restart Gateway」會啟動 shared home 上的 gateway supervisor (可能接手 agent 的 pending work), 非必要別按。 |
| **Hermes API server** | http://localhost:8642 | OpenAI-compatible gateway (`API_SERVER_KEY`). Swagger under `/docs` if exposed. |
| **Buzz** | http://localhost:3000 | Git repos browser (`BUZZ_SERVE_GIT_WEB_GUI`). Buzz's real surface is the **desktop app**: download Buzz Desktop, add workspace `ws://<this-machine-LAN-IP>:3000`, then ask the owner for an invite code (relay is closed by default — see below). |
| **TencentDB panel** | http://localhost:8125 | Log in with the admin key `TENCENTDB_ADMIN_USER_KEY` from `.env` (created automatically by the one-shot init-admin container). Create Teams/Agents/Tasks, browse memory (L0–L3). |
| **TencentDB knowledge** | http://localhost:8424/docs | Knowledge service Swagger (wiki / code-graph). |
| **TencentDB proxy** | http://localhost:8096 | LLM forward proxy with memory injection. Point a coding agent at it (see below). |

### Buzz: adding users (closed relay, default)

1. The relay identity is auto-generated into the `opc-keys` volume on first boot.
2. The relay owner's pubkey is already a member. For your desktop app and any
   other device: find the device's Nostr pubkey, then add it as a member:
   ```bash
   docker compose exec buzz sh -c \
     'DATABASE_URL="$DATABASE_URL" REDIS_URL="$REDIS_URL" \
      BUZZ_RELAY_PRIVATE_KEY=$(cat /keys/relay.nsec) RELAY_OWNER_PUBKEY=$(cat /keys/relay.pub) \
      BUZZ_RELAY_URL=http://localhost:3000 \
      buzz-admin add-member --pubkey <device-pubkey-hex> --role member'
   ```
3. In the Buzz desktop app, add workspace `ws://<this-machine-LAN-IP>:3000`.
   The relay also serves an invite landing page (`POST /api/invites` mints
   NIP-98 invite codes that `/invite/<code>` claims) if you prefer that flow.

The front-door Hermes (buzz-acp → `hermes acp`) is added as a relay member
automatically by the `buzz-bootstrap` one-shot container on first boot, and
runs in the relay's network namespace (its `BUZZ_RELAY_URL` is the same
`ws://localhost:3000` the relay's community binding is derived from). Chat
with it in any Buzz channel via @mention.

To open the relay instead (LAN-only self-hosting), set
`BUZZ_REQUIRE_RELAY_MEMBERSHIP=false` in `.env` before first `up` (any
pubkey can then connect; no invites needed).

## Agent wiring

- **Paperclip → Hermes**: in Paperclip create an agent with adapter
  `Hermes Gateway`: `apiBaseUrl: http://hermes:8642`, `apiKey: <HERMES_API_SERVER_KEY>`.
- **TencentDB Knowledge Plane (Hermes, PRD v10.1)**: the `memory_tencentdb`
  MemoryProvider is seeded into both Hermes containers (Buzz front door +
  gateway) and connects to the containerized MemoryCore gateway
  (`tencentdb-core:8420`; gateway key = `TENCENTDB_GATEWAY_API_KEY`). Memory
  scope: team `opc`; agent id = `agt-hermes-front-door` (front door; the
  `agt` prefix is required by the Memory Hub panel's asset-id parsing) or the
  active Hermes profile (gateway workers — per-profile memory via
  `agent_identity`). The `tencentdb-bootstrap` one-shot provisions the
  Team/Agent loadouts in the kernel meta registry automatically — the panel
  (http://localhost:8125) renders them without manual setup. Confirm
  `memory-tencentdb Gateway already running` in hermes/frontdoor logs.
- **TencentDB memory for other coding agents** (Codex/Claude/… — PRD phase K3,
  optional): point an agent's LLM base URL at the proxy
  `http://localhost:8096/<agent>/<spaceId>` with headers
  `x-team-id` / `x-agent-id` / `x-task-id` (create Team/Agent/Task in the
  panel first). See `upstream/tencentdb-agent-memory/INSTALL.md`.

## GitHub integration (dev flow → paperclip ticket → omp → gh → buzz link)

In Buzz (or the Hermes dashboard) tell the agent 「開發 xx」: the agent
clarifies, creates a Paperclip ticket, Paperclip's runtime invokes omp to
develop, omp runs `gh repo create --private --push` and posts the repo link
into the ticket, and a watcher in the frontdoor container posts the link to
your Buzz channel automatically. Paperclip never touches Buzz — all Buzz
traffic is the frontdoor agent's own identity.

Setup (one-time):

1. **Host prereqs**: `~/.ssh` (config + keys), `~/.config/gh` (logged in,
   `gh auth status`), `~/.gitconfig` (`[user] name/email`).
2. **Sync credentials** (any time they change on the host):
   ```bash
   scripts/sync-gh-creds.sh
   ```
   Copies `~/.ssh`, `~/.config/gh`, and git identity into the `opc_gh-creds`
   named volume (mounted at `/creds` in paperclip/hermes/frontdoor); rewrites
   ssh `IdentityFile` paths to the container layout and pre-seeds the
   `github.com` host key. Re-run after key/token changes — no rebuild needed.

The Paperclip admin/company/executor agent/API key are created automatically
by the `paperclip-bootstrap` one-shot (see Setup pages above); the frontdoor
and hermes entrypoints load `PAPERCLIP_API_KEY` from the keys volume at boot.

How it works: entrypoints set `GIT_SSH_COMMAND` / `GH_CONFIG_DIR` /
`GIT_CONFIG_GLOBAL` from `/creds` (paperclip's omp inherits them), the
`paperclip-api` skill teaches the agents the REST surface
(`POST /api/companies/<id>/issues` etc., bearer `PAPERCLIP_API_KEY`), and
`opc-issue-watcher.sh` polls the ticket (60s) then posts the GitHub link to
Buzz via the buzz CLI when the issue reaches `done`. The frontdoor entrypoint
re-attaches watchers for surviving tickets on every boot.

Verify / troubleshoot:

```bash
docker compose exec -u root paperclip sh -c '. /usr/local/bin/opc-gh-seed.sh && opc_gh_seed && gh auth status && ssh -F /creds/ssh/config -T git@github.com'
docker compose exec frontdoor cat /opt/data/issue-watchers/watcher.log
```

- `sweep: no companyId from /agents/me` in watcher.log → either
  `PAPERCLIP_API_KEY` missing/empty in `.env` (or wrong key scope), or the
  private-hostname guard blocked the call — `PAPERCLIP_ALLOWED_HOSTNAMES` in
  `.env` must contain `paperclip` (internal docker DNS name) plus any LAN IP
  you access the board from. `docker compose up -d paperclip` after changes.
- `Hostname 'X' is not allowed for this Paperclip instance` (browser/API from
  a LAN IP) → add X to `PAPERCLIP_ALLOWED_HOSTNAMES` in `.env`
  (comma-separated), then `docker compose up -d paperclip`.
- `gh auth status` fails → re-run `scripts/sync-gh-creds.sh`
  (`docker compose restart frontdoor hermes paperclip` re-applies key perms).

## Nix-based persistent tools (hermes, buzz, paperclip — OS level)

Install more tools (survives `compose down/up`, recreates, and image rebuilds):

```bash
docker compose exec hermes    nix profile add nixpkgs#<tool>
docker compose exec buzz      nix profile add nixpkgs#<tool>
docker compose exec frontdoor nix profile add nixpkgs#<tool>
docker compose exec -u root paperclip nix profile add nixpkgs#<tool>
```
Each boot self-heals: if the profile ever loses the preinstalled tools, the
entrypoint re-adds them automatically.

`omp` (Oh My Pi) — the Paperclip executor agent runtime — is auto-installed
into the paperclip container on first boot (and re-added if missing) from
`github:numtide/llm-agents.nix#omp` (binary cache: cache.numtide.com). It
runs as the `OMP Engineer` agent via the claude_local adapter with
`agentCommand: "omp acp --yolo"`.

Search: `nix search nixpkgs <name>`. Wipe a store: `docker volume rm opc_hermes-nix`.

## Isolation & privileges

- Containers run as **root** where the app tolerates it (buzz, frontdoor,
  hermes PID1); paperclip keeps its upstream `node`-user model (use
  `docker compose exec -u root paperclip bash` to tinker as root).
- Nothing is mounted from the host except named volumes inside this compose
  project. No `privileged`, no host pid/net mounts — container root cannot
  touch the host.
- All data (DBs, home dirs, git repos, keys) lives in the named volumes at
  the bottom of `docker-compose.yml`.

## Ports

| Port | Service |
|---|---|
| 3000 | Buzz relay (WS + REST + web UI) |
| 3100 | Paperclip (API + UI) |
| 8420 | TencentDB memory-core |
| 8125 | TencentDB panel UI |
| 8424 | TencentDB knowledge service |
| 8096 | TencentDB proxy |
| 8642 | Hermes API server |
| 9119 | Hermes dashboard |

## Useful commands

```bash
docker compose ps                     # status
docker compose logs -f <service>      # logs
docker compose down                   # stop (volumes persist)
docker compose down -v                # DANGER: wipe all data
docker compose exec hermes hermes --help
docker compose exec frontdoor hermes --version
```

## Known limitations
- Hermes has no first-class omp dispatch; omp is reachable through Hermes'
  bash tool as a normal CLI (see AGENTS.md for the Paperclip↔omp ACP route).
- The TencentDB `MemoryKnowledge/Dockerfile` is broken upstream at v2.0.0
  (missing `docker/entrypoint.sh`); this stack uses the supported
  `deploy/panel-knowledge-combined` image for the hub instead.
- Buzz has no web chat UI; conversation happens in the Buzz desktop/mobile
  clients against this relay.
