# OPC stack image for Paperclip — adapted from the upstream Dockerfile.
# The tag it was last reconciled against is NOT written here; that would be a
# second copy of a fact `scripts/outdated.sh` already derives, and this comment
# would go stale exactly like the ones it replaced. What keeps this file honest
# is `scripts/upgrade-preflight.sh`, which reports "adapted-from source CHANGED"
# whenever upstream edits its Dockerfile — that is how the
# `packages/tailscale-https-broker` workspace manifest below was caught.
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
#
# This ARG MUST precede the FIRST FROM in the file, not merely its own FROM —
# an ARG used in a FROM only has global scope (visible to every later FROM)
# when declared before any stage begins; declared after one it is scoped to
# that stage alone, and the following FROM sees an empty value ("base name
# should not be blank").
ARG NIX_SEED_IMAGE=opc/nix-seed:local

# Shared seed (nix + 12 tools) built once in patches/nix-seed (compose service
# `nix-seed`); a tool-list change rebuilds only that image. Seed image alias:
# COPY --from cannot expand variables (BuildKit), so the global
# NIX_SEED_IMAGE ARG (compose passes the IMAGE_PREFIX-qualified name) is
# materialized as a stage and copied from by name. The COPY --from=nix-seed
# in the runtime stage below consumes it.
FROM ${NIX_SEED_IMAGE} AS nix-seed

# RustFS provisioning client. This exact build is covered by tests/devenv-s3.sh.
FROM minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727 AS minio-client

FROM node:24-trixie-slim AS base
ARG USER_UID=1000
ARG USER_GID=1000
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates gosu curl gh git wget ripgrep python3 tini \
       postgresql-client redis-tools amqp-tools \
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
COPY packages/paperclip-eval-kernel/package.json packages/paperclip-eval-kernel/
COPY packages/paperclip-runner/package.json packages/paperclip-runner/
COPY packages/skills-catalog/package.json packages/skills-catalog/
COPY packages/tailscale-https-broker/package.json packages/tailscale-https-broker/
COPY packages/teams-catalog/package.json packages/teams-catalog/
COPY packages/adapters/claude-local/package.json packages/adapters/claude-local/
COPY packages/adapters/codex-local/package.json packages/adapters/codex-local/
COPY packages/adapters/cursor-cloud/package.json packages/adapters/cursor-cloud/
COPY packages/adapters/cursor-local/package.json packages/adapters/cursor-local/
COPY packages/adapters/gemini-local/package.json packages/adapters/gemini-local/
COPY packages/adapters/grok-local/package.json packages/adapters/grok-local/
COPY packages/adapters/kimi-local/package.json packages/adapters/kimi-local/
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

# Reconcile the declared runtime graph and scoped terminal package patches
# before frozen installation; the build-only patch tool never enters runtime.
COPY opc/patches/server-runtime-dependencies-lock.patch opc/patches/acpx-terminal-env.patch /tmp/
RUN apt-get update \
  && apt-get install -y --no-install-recommends patch \
  && rm -rf /var/lib/apt/lists/* \
  && patch -p1 --fuzz=0 --no-backup-if-mismatch < /tmp/acpx-terminal-env.patch \
  && patch -p1 --fuzz=0 --no-backup-if-mismatch < /tmp/server-runtime-dependencies-lock.patch \
  && rm /tmp/server-runtime-dependencies-lock.patch /tmp/acpx-terminal-env.patch
RUN pnpm install --frozen-lockfile

FROM base AS rust-toolchain
WORKDIR /app
# Upstream v2026.916.0+: Debian's packaged rust (trixie ships 1.85) lags the
# runner's dependency tree — install rustup (pinned, checksum-verified) and let
# the runner's own rust-toolchain.toml choose the compiler. OPC keeps this
# block in sync with upstream Dockerfile; the old `apt cargo rustc` no longer
# builds the runner.
RUN apt-get update \
  && apt-get install -y --no-install-recommends gcc libc6-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
ARG RUSTUP_VERSION=1.29.0
ARG RUSTUP_SHA256_AMD64=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
ARG RUSTUP_SHA256_ARM64=9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) rustTarget="x86_64-unknown-linux-gnu"; sha256="$RUSTUP_SHA256_AMD64" ;; \
      arm64) rustTarget="aarch64-unknown-linux-gnu"; sha256="$RUSTUP_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustTarget}/rustup-init"; \
    echo "${sha256}  /tmp/rustup-init" | sha256sum -c -; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain none; \
    rm /tmp/rustup-init
COPY packages/paperclip-runner/rust-toolchain.toml /tmp/runner-toolchain/rust-toolchain.toml
RUN cd /tmp/runner-toolchain && rustup show

FROM rust-toolchain AS rust-chef
RUN cd /tmp/runner-toolchain && cargo install cargo-chef --version 0.1.73 --locked

FROM rust-chef AS runner-plan
WORKDIR /app/packages/paperclip-runner
COPY packages/paperclip-runner/rust-toolchain.toml ./
COPY packages/paperclip-runner/runner ./runner
RUN cd runner && cargo chef prepare --recipe-path /tmp/runner-recipe.json

FROM rust-chef AS runner-deps
WORKDIR /app/packages/paperclip-runner/runner
COPY packages/paperclip-runner/rust-toolchain.toml ../
COPY --from=runner-plan /tmp/runner-recipe.json /tmp/runner-recipe.json
RUN cargo chef cook --release --locked --package paperclip-runner-core --bin paperclip-runnerd --recipe-path /tmp/runner-recipe.json \
  && find . -mindepth 1 -maxdepth 1 ! -name target -exec rm -rf {} +

FROM runner-deps AS runner-build
WORKDIR /app/packages/paperclip-runner
COPY packages/paperclip-runner/rust-toolchain.toml ./
COPY packages/paperclip-runner/runner ./runner
COPY packages/paperclip-runner/protocol ./protocol
RUN find runner protocol -type f -exec touch -d @0 {} + \
  && touch -d @0 rust-toolchain.toml \
  && cargo build --release --manifest-path runner/Cargo.toml --locked -p paperclip-runner-core --bin paperclip-runnerd

FROM runner-build AS build
WORKDIR /app
COPY --from=deps /app /app
# opc/ (OPC overlay, synced from patches/) is copied explicitly in the
# production stage; excluding it keeps entrypoint/script edits from
# invalidating the pnpm build cache.
# Keep the reconciled lock from deps for later provider-pack deployment too.
COPY --exclude=opc --exclude=pnpm-lock.yaml . .
# The frozen graph hashes these corrected patches. Do not let the full source
# copy silently restore older bytes before provider-pack deployment.
COPY --from=deps /app/patches/acpx@0.12.0.patch /app/patches/acpx@0.13.1.patch patches/
# The local omp ACP command needs the container's shared tool/resource roots.
# Keep the closed host projection intact; the adapter contributes only OPC
# capabilities, and remote callers still supply no host environment.
COPY --from=deps /usr/bin/patch /usr/local/bin/opc-build-patch
COPY opc/patches/omp-acpx-runtime-env.patch opc/patches/task-bound-runtime-mcp.patch /tmp/
RUN opc-build-patch -p1 --fuzz=0 --no-backup-if-mismatch < /tmp/omp-acpx-runtime-env.patch \
  && opc-build-patch -p1 --fuzz=0 --no-backup-if-mismatch < /tmp/task-bound-runtime-mcp.patch \
  && rm /tmp/omp-acpx-runtime-env.patch /tmp/task-bound-runtime-mcp.patch /usr/local/bin/opc-build-patch
RUN find packages/paperclip-runner/runner packages/paperclip-runner/protocol -type f -exec touch -d @0 {} + \
  && touch -d @0 packages/paperclip-runner/rust-toolchain.toml
# Both the browser bundle and server stamp need the exact source commit.
# Declare it after dependency layers, before either application build.
ARG PAPERCLIP_BUILD_COMMIT=""
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
# The server build runs scripts/write-build-stamp.mjs, which stamps the built
# commit into dist/build-info.json. The build context has no .git, so the
# script reads PAPERCLIP_BUILD_COMMIT instead. Docker exposes the ARG above
# to each build RUN; production declares it again for the runtime fallback.
ENV NODE_OPTIONS=--max-old-space-size=4096
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)
RUN rm -rf packages/paperclip-runner/runner/target

# Ship the target's controller-owned remote provider pack without changing
# OPC's local omp ACP configuration. An unstamped local build cannot qualify
# a remote pack; never substitute a fabricated source revision.
FROM build AS runner-provider-pack
RUN mkdir -p /provider-pack \
  && if [ -n "${PAPERCLIP_BUILD_COMMIT}" ]; then \
    PAPERCLIP_RUNNER_SOURCE_REVISION="${PAPERCLIP_BUILD_COMMIT}" node packages/paperclip-runner/scripts/build-provider-pack.mjs /provider-pack; \
  else \
    echo "Skipping remote provider pack: supply a full PAPERCLIP_BUILD_COMMIT to enable remote OpenCode/ACPX execution"; \
  fi

FROM base AS production
ARG USER_UID=1000
ARG USER_GID=1000
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
  && npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai @google/gemini-cli@latest @moonshot-ai/kimi-code@latest \
  && apt-get update \
  && apt-get install -y --no-install-recommends openssh-client jq podman-remote \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /paperclip \
  && chown node:node /paperclip

COPY scripts/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

COPY --chown=node:node --from=build /app /app

COPY --from=runner-provider-pack /provider-pack /opt/paperclip-runner/provider-pack
# This immutable, root-owned pack contains public code/integrity metadata,
# not credentials. It must stay readable even after the runtime UID remap.
RUN chmod -R a+rX /opt/paperclip-runner/provider-pack \
  && if [ -f /opt/paperclip-runner/provider-pack/provider-pack.json ]; then \
    gosu 65534:65534 node -e 'const fs = require("node:fs"); const path = require("node:path"); const root = "/opt/paperclip-runner/provider-pack"; const manifest = JSON.parse(fs.readFileSync(path.join(root, "provider-pack.json"), "utf8")); for (const artifact of Object.values(manifest.payload.artifacts)) fs.readFileSync(path.join(root, artifact.path)); fs.accessSync(path.join(root, manifest.payload.artifacts.nodeCommand.path), fs.constants.X_OK);'; \
  fi
ENV PAPERCLIP_RUNNER_REMOTE_PROVIDER_PACK_PATH=/opt/paperclip-runner/provider-pack

# Declare per-build metadata after the stable RUN layers (upstream ordering
# since v2026.916.0): Docker includes in-scope ARG values in a RUN's
# environment even when its command does not mention them; declaring these
# earlier invalidates the weekly tool cache above. The build stage still
# receives the commit before writing dist/build-info.json. Empty for local
# builds — /api/health then reports its normal fallback.
ARG PAPERCLIP_BUILD_VERSION=""
ARG PAPERCLIP_BUILD_COMMIT=""
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
# podenv CLI + its control schema (the nested container lease lane).
COPY opc/podenv/ /usr/local/lib/podenv/
COPY opc/opc-podenv-seed.sh /usr/local/bin/opc-podenv-seed.sh
# The podman CLIENT: Debian's own `podman-remote` package (installed in the
# apt layer above), symlinked to the plain name an agent types.
#
# NOT `COPY --from=podenv /usr/bin/podman` (measured to fail, and previously
# the approach here): quay.io/podman/stable is Fedora, and its podman binary
# is dynamically linked against Fedora's libc/libselinux/libsemanage/libpam/
# libgpgme/etc — none of which exist (or exist with a compatible ABI) on this
# image's Debian trixie base. Running the bare copy dies at the loader with
# "libsubid.so.5: cannot open shared object file" (plus 22 more missing
# libraries). The reasoning for copying the binary in the first place — same
# build, so client and server versions can never skew — was a precaution, not
# a measurement, and it does not survive contact with one: Debian trixie's
# podman-remote is 5.4.2 against a 5.8.4 runtime host, and that gap changes
# NOTHING this lane exercises. Measured directly against the running podenv
# service: `version` reports `server: 5.8.4` correctly, and `run`, `ps`,
# `build` (built and tagged an image), `image inspect`, and `system df` all
# succeed. So: apt's package, not a vendored Fedora closure plus a private
# linker wrapper (~44MB binary + 23 libraries) to work around a version
# mismatch that costs nothing. If a future skew ever DOES break one of these
# operations, that is the thing to fix (pin a newer podman-remote, or point
# at a backports/testing package) — not to re-reach for copying the binary,
# which trades a measured, harmless version gap for an unmeasured, expensive
# ABI mismatch. The symlink itself is made below, alongside devenv/podenv/
# prototype's.
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
COPY opc/agent-prompts/ /opt/opc-agent-prompts/
COPY opc/opc-paperclip-bootstrap.sh /usr/local/bin/opc-paperclip-bootstrap.sh
COPY opc/nix-entrypoint.sh /usr/local/bin/nix-entrypoint.sh
RUN chmod +x /usr/local/bin/opc-nix-seed.sh /usr/local/bin/opc-mise-seed.sh \
             /usr/local/bin/opc-gh-seed.sh /usr/local/bin/opc-claude-seed.sh \
             /usr/local/bin/opc-devenv-seed.sh /usr/local/bin/opc-podenv-seed.sh \
             /usr/local/bin/opc-prototype-restore.sh \
             /usr/local/bin/opc-paperclip-bootstrap.sh /usr/local/bin/nix-entrypoint.sh \
    && chmod +x /usr/local/lib/devenv/devenv /usr/local/lib/devenv/providers/*.sh \
    && chmod +x /usr/local/lib/podenv/podenv \
    && chmod +x /usr/local/lib/prototype/prototype \
    && ln -sf /usr/local/lib/devenv/devenv /usr/local/bin/devenv \
    && ln -sf /usr/local/lib/podenv/podenv /usr/local/bin/podenv \
    && ln -sf /usr/local/lib/prototype/prototype /usr/local/bin/prototype \
    && ln -sf /usr/bin/podman-remote /usr/local/bin/podman

# Shared seed (nix + 12 tools) from the nix-seed stage (see stage alias
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
COPY --from=minio-client /usr/bin/mc /usr/local/bin/mc
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

# Set in the image ENV, not only exported by the entrypoint: `docker exec`
# interactive sessions do not inherit entrypoint-time exports (AGENTS.md
# records this for GH_CONFIG_DIR / GIT_SSH_COMMAND / GIT_CONFIG_GLOBAL), and
# an agent debugging by hand needs the wide `podman` interface to just work.
#
# Measured (all three forms reach the runtime host's 5.8.4): `podman-remote
# --remote --url unix:///run/podenv/podman.sock version`; the `podman` symlink
# above with CONTAINER_HOST set and no flags at all; and `podman --remote
# --url ... version` through that same symlink. So the skill's examples can
# say plain `podman run`, not `podman-remote --remote --url ... run`.
ENV CONTAINER_HOST=unix:///run/podenv/podman.sock \
    PODENV_LIB=/usr/local/lib/podenv

ENTRYPOINT ["/usr/local/bin/nix-entrypoint.sh", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]
