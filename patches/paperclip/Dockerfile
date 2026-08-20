# OPC stack image for Paperclip — adapted from the upstream Dockerfile
# (paperclipai/paperclip @ tag v2026.817.0).
# Changes vs upstream:
#   1. Single-user Nix layer: OS tools installed via `nix profile install`
#      persist on the /nix volume across compose down/up and recreates.
#   2. Entrypoint wrapper seeds the /nix volume before the upstream
#      docker-entrypoint.sh (uid remap + gosu node) takes over.
#   3. Upstream's `cloud` / `cloud-plugins` stages are omitted: compose builds
#      this file with no --target, so the LAST stage wins. Keeping them would
#      silently make `cloud` the default image. The OPC overlay below is
#      appended to `production` and must stay the final stage.

# syntax=docker/dockerfile:1.20
# Shared nix seed image (compose passes the IMAGE_PREFIX-qualified name).
# Declared globally so FROM ${NIX_SEED_IMAGE} expands; the `nix-seed` stage
# below materializes it for COPY --from (which cannot expand variables).
ARG NIX_SEED_IMAGE=opc/nix-seed:local
# Shared seed (nix + 8 tools) built once in patches/nix-seed (compose service
# `nix-seed`); a tool-list change rebuilds only that image. Seed image alias:
# COPY --from cannot expand variables (BuildKit), so the global
# NIX_SEED_IMAGE ARG (compose passes the IMAGE_PREFIX-qualified name) is
# materialized as a stage and copied from by name. The COPY --from=nix-seed
# in the runtime stage below consumes it.
FROM ${NIX_SEED_IMAGE} AS nix-seed
FROM node:lts-trixie-slim AS base
ARG USER_UID=1000
ARG USER_GID=1000
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates gosu curl gh git wget ripgrep python3 \
       postgresql-client redis-tools \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable

# Modify the existing node user/group to have the specified UID/GID to match host user
RUN usermod -u $USER_UID --non-unique node \
  && groupmod -g $USER_GID --non-unique node \
  && usermod -g $USER_GID -d /paperclip node

FROM base AS deps
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
COPY cli/package.json cli/
COPY server/package.json server/
COPY ui/package.json ui/
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/adapter-utils/package.json packages/adapter-utils/
COPY packages/google-sheets-mcp-server/package.json packages/google-sheets-mcp-server/
COPY packages/kv-demo-mcp-server/package.json packages/kv-demo-mcp-server/
COPY packages/mcp-server/package.json packages/mcp-server/
COPY packages/skills-catalog/package.json packages/skills-catalog/
COPY packages/teams-catalog/package.json packages/teams-catalog/
COPY packages/adapters/claude-local/package.json packages/adapters/claude-local/
COPY packages/adapters/codex-local/package.json packages/adapters/codex-local/
COPY packages/adapters/cursor-cloud/package.json packages/adapters/cursor-cloud/
COPY packages/adapters/cursor-local/package.json packages/adapters/cursor-local/
COPY packages/adapters/gemini-local/package.json packages/adapters/gemini-local/
COPY packages/adapters/grok-local/package.json packages/adapters/grok-local/
COPY packages/adapters/hermes/package.json packages/adapters/hermes/
COPY packages/adapters/hermes-gateway/package.json packages/adapters/hermes-gateway/
COPY packages/adapters/openclaw-gateway/package.json packages/adapters/openclaw-gateway/
COPY packages/adapters/opencode-local/package.json packages/adapters/opencode-local/
COPY packages/adapters/pi-local/package.json packages/adapters/pi-local/
COPY packages/plugins/sdk/package.json packages/plugins/sdk/
COPY --parents packages/plugins/sandbox-providers/./*/package.json packages/plugins/sandbox-providers/
COPY packages/plugins/paperclip-plugin-fake-sandbox/package.json packages/plugins/paperclip-plugin-fake-sandbox/
COPY packages/plugins/plugin-llm-wiki/package.json packages/plugins/plugin-llm-wiki/
COPY packages/plugins/plugin-workspace-diff/package.json packages/plugins/plugin-workspace-diff/
COPY patches/ patches/
COPY scripts/link-plugin-dev-sdk.mjs scripts/

RUN pnpm install --frozen-lockfile

FROM base AS build
WORKDIR /app
COPY --from=deps /app /app
# opc/ (OPC overlay, synced from patches/) is copied explicitly in the
# production stage; excluding it keeps entrypoint/script edits from
# invalidating the pnpm build cache.
COPY --exclude=opc . .
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

FROM base AS production
ARG USER_UID=1000
ARG USER_GID=1000
# Version/commit stamps: the image has no .git, so server-info cannot derive
# them at runtime and falls back to these. Empty for local builds, which is
# what compose does — /api/health then reports its normal fallback.
ARG PAPERCLIP_BUILD_VERSION=""
ARG PAPERCLIP_BUILD_COMMIT=""
# Busts the tool layer below when it changes (upstream CI stamps an ISO week
# so the @latest CLIs advance weekly). Empty here: the OPC stack pins its
# rebuilds to explicit upgrades, so the tools move when we say so.
ARG CLI_TOOLS_CACHE_EPOCH=""
WORKDIR /app
# Tool + OS layer BEFORE the app copy (upstream ordering since v2026.817.0):
# it references nothing from /app, and the app copy changes on every commit —
# ordered the other way this layer (four CLI toolchains + apt, the most
# expensive one in the file) could never hit the cache.
RUN echo "cli-tools-epoch: ${CLI_TOOLS_CACHE_EPOCH}" \
  && npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai @google/gemini-cli@latest \
  && apt-get update \
  && apt-get install -y --no-install-recommends openssh-client jq \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /paperclip \
  && chown node:node /paperclip

COPY scripts/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

COPY --chown=node:node --from=build /app /app

ENV NODE_ENV=production \
  PAPERCLIP_BUILD_VERSION=${PAPERCLIP_BUILD_VERSION} \
  PAPERCLIP_BUILD_COMMIT=${PAPERCLIP_BUILD_COMMIT} \
  HOME=/paperclip \
  HOST=0.0.0.0 \
  PORT=3100 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  USER_UID=${USER_UID} \
  USER_GID=${USER_GID} \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
  OPENCODE_ALLOW_ALL_MODELS=true \
  GEMINI_SANDBOX=false

EXPOSE 3100

# ---------- OPC stack overlay: nix tool persistence ----------
COPY opc/nix-seed.sh /usr/local/bin/opc-nix-seed.sh
COPY opc/opc-mise-seed.sh /usr/local/bin/opc-mise-seed.sh
COPY opc/opc-gh-seed.sh /usr/local/bin/opc-gh-seed.sh
COPY opc/opc-claude-seed.sh /usr/local/bin/opc-claude-seed.sh
COPY opc/opc-devenv-seed.sh /usr/local/bin/opc-devenv-seed.sh
COPY opc/opc-prototype-restore.sh /usr/local/bin/opc-prototype-restore.sh
# devenv CLI + providers + control schema (see the devenv spec).
COPY opc/devenv/ /usr/local/lib/devenv/
# `prototype` CLI: the paperclip-aware workflow layer (project + git + lease).
# Kept out of devenv on purpose — devenv must stay a generic resource lease
# with no knowledge of Paperclip. See the header of opc/prototype/prototype.
COPY opc/prototype/ /usr/local/lib/prototype/
# Scaffolds for `prototype create --template`. Code, not documentation: the
# non-obvious parts (env precedence, NODE_ENV, allowedDevOrigins, the valkey
# ready check) were each a debugging session, and an agent retyping them from
# prose gets them wrong — which is how they were found.
COPY opc/templates/ /usr/local/lib/prototype/templates/
# Vendored third-party skills, installed into the company library by
# opc-paperclip-bootstrap.sh (Paperclip's GitHub importer drops sibling files).
COPY opc/skills/ /opt/opc-skills/
COPY opc/opc-paperclip-bootstrap.sh /usr/local/bin/opc-paperclip-bootstrap.sh
COPY opc/nix-entrypoint.sh /usr/local/bin/nix-entrypoint.sh
RUN chmod +x /usr/local/bin/opc-nix-seed.sh /usr/local/bin/opc-mise-seed.sh \
             /usr/local/bin/opc-gh-seed.sh /usr/local/bin/opc-claude-seed.sh \
             /usr/local/bin/opc-devenv-seed.sh /usr/local/bin/opc-prototype-restore.sh \
             /usr/local/bin/opc-paperclip-bootstrap.sh /usr/local/bin/nix-entrypoint.sh \
    && chmod +x /usr/local/lib/devenv/devenv /usr/local/lib/devenv/providers/*.sh \
    && chmod +x /usr/local/lib/prototype/prototype \
    && ln -sf /usr/local/lib/devenv/devenv /usr/local/bin/devenv \
    && ln -sf /usr/local/lib/prototype/prototype /usr/local/bin/prototype

# Shared seed (nix + 8 tools) from the nix-seed stage (see stage alias
# above); a tool-list change rebuilds only the nix-seed image.
# `nixagents` (gid 3000) is how an unprivileged agent gets write access to
# the shared nix profile on the opc-nix volume. The GID must be identical
# across every image: the volume is shared, so the kernel compares the
# NUMBER, not the name. Unifying the runtime UIDs instead was rejected —
# paperclip's uid 1000 belongs to the upstream node base image, and the
# existing home volumes are owned by the current uids (invariant 3b).
RUN groupadd -r nixbld \
    && useradd -r -g nixbld -d /var/empty -s /usr/sbin/nologin nixbld1 \
    && gpasswd -a nixbld1 nixbld \
    && groupadd -g 3000 nixagents \
    && usermod -aG nixagents node \
    && mkdir -m 0755 /nix
COPY --from=nix-seed /nix-seed /nix-seed
# PATH order is load-bearing. The seed (system) profile stays FIRST so an
# agent cannot shadow a system tool: nix-seed self-heal checks the system
# profile by path, but everything else on the stack resolves through PATH.
# The shared agent profile follows it — installed once, present in every
# container — and /nix/var/nix/opc-bin carries the nix-add/nix-rm/nix-list
# wrappers the daemon publishes onto the volume.
ENV PATH="/nix/var/nix/profiles/per-user/root/profile/bin:/nix/var/nix/profiles/opc-agents/profile/bin:/nix/var/nix/opc-bin:/nix/var/nix/profiles/default/bin:${PATH}:/opt/mise/shims" \
    NIX_PROFILES="/nix/var/nix/profiles/default /nix/var/nix/profiles/per-user/root /nix/var/nix/profiles/opc-agents/profile" \
    NIX_USER_CONF_FILES="/nix/etc/nix/nix.conf" \
    NIX_SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"

# Login shells re-derive PATH from /etc/profile and drop the ENV above — a
# pre-existing gap (`bash -lc 'jq --version'` already failed here) that now
# also hides nix-add. profile.d puts the same entries back, idempotently.
RUN printf '%s\n' \
    '_opc="/nix/var/nix/profiles/per-user/root/profile/bin:/nix/var/nix/profiles/opc-agents/profile/bin:/nix/var/nix/opc-bin:/nix/var/nix/profiles/default/bin"' \
    'case ":$PATH:" in' \
    '    *":/nix/var/nix/opc-bin:"*) ;;' \
    '    *) PATH="$_opc:$PATH:/opt/mise/shims" ;;' \
    'esac' \
    'export PATH' \
    'unset _opc' \
    > /etc/profile.d/opc-nix.sh

# mise-managed toolchains (node/rust/omp) live on the persistent *-mise volume
# (opc-mise-seed.sh); PATH tail keeps the baked node 24 authoritative, and
# /opt/mise/shims on the image PATH tail lets docker exec reach omp/rustc/cargo.
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_CONFIG_DIR=/opt/mise/config

ENTRYPOINT ["/usr/local/bin/nix-entrypoint.sh", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]
