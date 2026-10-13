# syntax=docker/dockerfile:1.19
# OPC Hermes v0.21.7: upstream PM/runtime/products with OPC persistent tools and identities.
ARG NIX_SEED_IMAGE=opc/nix-seed:local
ARG BUZZ_IMAGE=opc/frontdoor:local
FROM ${NIX_SEED_IMAGE} AS nix-seed
FROM ${BUZZ_IMAGE} AS buzz-cli
# Debian 13 still ships SQLite 3.46.1, which contains the upstream WAL-reset
# corruption bug. Build a pinned shared library for the runtime image instead
# of relying on a distro backport that trixie does not currently provide.
# See #70480 and https://sqlite.org/wal.html#walresetbug.
# Pinned by the multi-arch index digest: uv and node already come from pm's
# sha-verified lock, and a tag alone would let the base drift under them.
FROM debian:13.4@sha256:e2d08da6f42ef4b09b165d55528a12727aeed8240dc9edf888e3ec07e10ef9da AS sqlite_build
ARG SQLITE_AUTOCONF_VERSION=3530400
ARG SQLITE_SHA256=0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c
RUN apt-get -o Acquire::Retries=3 update && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        build-essential ca-certificates curl && \
    rm -rf /var/lib/apt/lists/* && \
    (curl -fsSL --retry 1 --retry-all-errors --connect-timeout 15 --max-time 60 \
        -o /tmp/sqlite.tar.gz \
        "https://sqlite.org/2026/sqlite-autoconf-${SQLITE_AUTOCONF_VERSION}.tar.gz" || \
     curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 120 \
        -o /tmp/sqlite.tar.gz \
        "https://sources.buildroot.net/sqlite/sqlite-autoconf-${SQLITE_AUTOCONF_VERSION}.tar.gz") && \
    printf '%s  %s\n' "${SQLITE_SHA256}" /tmp/sqlite.tar.gz > /tmp/sqlite.sha256 && \
    sha256sum -c /tmp/sqlite.sha256 && \
    tar -xzf /tmp/sqlite.tar.gz -C /tmp && \
    cd "/tmp/sqlite-autoconf-${SQLITE_AUTOCONF_VERSION}" && \
    CFLAGS="-O2 \
        -DSQLITE_ENABLE_FTS3 \
        -DSQLITE_ENABLE_FTS3_PARENTHESIS \
        -DSQLITE_ENABLE_FTS4 \
        -DSQLITE_ENABLE_FTS5 \
        -DSQLITE_ENABLE_RTREE \
        -DSQLITE_ENABLE_GEOPOLY \
        -DSQLITE_ENABLE_COLUMN_METADATA \
        -DSQLITE_ENABLE_UNLOCK_NOTIFY \
        -DSQLITE_ENABLE_DBSTAT_VTAB \
        -DSQLITE_ENABLE_DBPAGE_VTAB \
        -DSQLITE_ENABLE_MATH_FUNCTIONS \
        -DSQLITE_ENABLE_PREUPDATE_HOOK \
        -DSQLITE_ENABLE_SESSION \
        -DSQLITE_SECURE_DELETE \
        -DSQLITE_THREADSAFE=1 \
        -DSQLITE_MAX_VARIABLE_NUMBER=250000" \
        ./configure --prefix=/opt/sqlite-fixed --disable-static && \
    make -j"$(nproc)" && \
    make install

# Same digest as sqlite_build: the built libsqlite must match this libc.
FROM debian:13.4@sha256:e2d08da6f42ef4b09b165d55528a12727aeed8240dc9edf888e3ec07e10ef9da AS runtime_base

# Disable Python stdout buffering to ensure logs are printed immediately.
# Do not write .pyc files at runtime: /opt/hermes is immutable in the
# published container and writable state belongs under /opt/data.
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# The pm-pinned full Chromium lives in the managed tool store at
# /opt/hermes/tools — outside the /opt/data volume mount, so the
# build-time install survives the volume overlay at runtime. pm's
# chromium package fact exports the same value (PLAYWRIGHT_BROWSERS_PATH
# at the store root); the image ENV names the same directory so
# Playwright and the browser tool resolve the pinned build even before pm
# composes tool env.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/tools

# Install system dependencies in one layer, clear APT cache.
# tini was previously PID 1 to reap orphaned zombie processes (MCP stdio
# subprocesses, git, bun, etc.) that would otherwise accumulate when hermes
# ran as PID 1. See #15012. Phase 2 of the s6-overlay supervision plan
# replaces tini with s6-overlay's /init (PID 1 = s6-svscan), which reaps
# zombies non-blockingly on SIGCHLD and additionally supervises the main
# hermes process, the dashboard, and per-profile gateways.
# The second package list is the shared libraries the pinned Chromium links
# against. `npx playwright install --with-deps` used to apt-install them as
# a side effect; pm stages the pinned browser instead (below), so the libs
# must be declared here. The list is the `ldd ... | grep "not found"` set of
# the pinned chrome binary in this base image, mapped to trixie package
# names (see .hermes/plans/termux-removal-commit-spec.md).
RUN apt-get -o Acquire::Retries=3 update && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
    ca-certificates curl iputils-ping python3 python-is-python3 gcc g++ make cmake python3-dev python3-venv libffi-dev libolm-dev libatomic1 procps git openssh-client docker-cli xz-utils \
    libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64 libdbus-1-3 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 && \
    rm -rf /var/lib/apt/lists/*

# Bot Screen (opt-in): PACKAGES["apt"] from tools/bot_desktop/runtime.py plus apt
# `chromium` for the restricted-userns sandbox fallback. PM already stages
# pinned full Chromium for both variants; no separate Playwright install.
# Nothing starts
# at boot. docker.yml builds both variants and publishes these packages under
# the `-desktop` tags: hosted sandboxes pull a prebuilt image and never run a
# build, and cannot apt at run time either (unprivileged, no sudo). Only this
# build step needs root —
# Xvnc is a userspace X server, so the runtime user can drive it.
#   docker build --build-arg HERMES_BOT_DESKTOP=1 .
ARG HERMES_BOT_DESKTOP=0
RUN if [ "$HERMES_BOT_DESKTOP" = "1" ]; then \
        apt-get -o Acquire::Retries=3 update && \
        DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        tigervnc-standalone-server xfce4-panel xfwm4 xfdesktop4 xfce4-settings xfce4-terminal \
        dbus-x11 x11-xserver-utils x11-utils x11-xkb-utils xauth fonts-dejavu-core chromium && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Prefer the fixed SQLite over Debian's vulnerable libsqlite3.so.0. Keep the
# public library name stable so both the system interpreter and the uv-created
# venv resolve the replacement without changing Python import paths.
COPY --from=sqlite_build /opt/sqlite-fixed/lib/libsqlite3.so.3.53.4 /usr/local/lib/
RUN ln -sf libsqlite3.so.3.53.4 /usr/local/lib/libsqlite3.so.0 && \
    ln -sf libsqlite3.so.3.53.4 /usr/local/lib/libsqlite3.so && \
    printf '/usr/local/lib\n' > /etc/ld.so.conf.d/000-sqlite-fixed.conf && \
    ldconfig && \
    python3 -c "import sqlite3, sys; \
v = sqlite3.sqlite_version_info; \
sys.exit(f'linked SQLite {sqlite3.sqlite_version} still has the WAL-reset bug') if v < (3, 51, 3) else None; \
db = sqlite3.connect(':memory:'); \
db.execute(\"CREATE VIRTUAL TABLE docs USING fts5(content, tokenize='trigram')\"); \
db.execute(\"INSERT INTO docs VALUES ('hermes')\"); \
sys.exit('SQLite FTS5 trigram self-test failed') if db.execute(\"SELECT count(*) FROM docs WHERE docs MATCH 'erm'\").fetchone()[0] != 1 else None; \
db.close()"

# ---------- s6-overlay install ----------
# s6-overlay provides supervision for the main hermes process, the dashboard,
# and per-profile gateways. /init becomes PID 1 below — see ENTRYPOINT.
#
# Multi-arch: BuildKit auto-populates TARGETARCH (amd64 / arm64). s6-overlay
# uses tarball names keyed on the kernel arch string (x86_64 / aarch64), so
# we map between them inline. The noarch + symlinks tarballs are
# architecture-independent and reused as-is.
#
# We use `curl` instead of `ADD` for ALL three tarballs: `ADD` evaluates its
# URL at parse time (no ARG / TARGETARCH substitution) and — critically for
# CI reliability — cannot retry, so a single GitHub-release CDN blip fails
# the whole 15-45 min build. curl -fsSL --retry 3 self-heals those blips,
# and every tarball is still checksum-verified below before extraction.
ARG TARGETARCH
ARG S6_OVERLAY_VERSION=3.2.3.0
ARG S6_OVERLAY_NOARCH_SHA256=b720f9d9340efc8bb07528b9743813c836e4b02f8693d90241f047998b4c53cf
ARG S6_OVERLAY_X86_64_SHA256=a93f02882c6ed46b21e7adb5c0add86154f01236c93cd82c7d682722e8840563
ARG S6_OVERLAY_AARCH64_SHA256=0952056ff913482163cc30e35b2e944b507ba1025d78f5becbb89367bf344581
ARG S6_OVERLAY_SYMLINKS_SHA256=a60dc5235de3ecbcf874b9c1f18d73263ab99b289b9329aa950e8729c4789f0e
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) s6_arch="x86_64"; s6_arch_sha="${S6_OVERLAY_X86_64_SHA256}" ;; \
        arm64) s6_arch="aarch64"; s6_arch_sha="${S6_OVERLAY_AARCH64_SHA256}" ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH} for s6-overlay" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}"; \
    curl -fsSL --retry 3 -o /tmp/s6-overlay-noarch.tar.xz \
        "${base}/s6-overlay-noarch.tar.xz"; \
    curl -fsSL --retry 3 -o /tmp/s6-overlay-symlinks-noarch.tar.xz \
        "${base}/s6-overlay-symlinks-noarch.tar.xz"; \
    curl -fsSL --retry 3 -o /tmp/s6-overlay-arch.tar.xz \
        "${base}/s6-overlay-${s6_arch}.tar.xz"; \
    { \
        printf '%s  %s\n' "${S6_OVERLAY_NOARCH_SHA256}" /tmp/s6-overlay-noarch.tar.xz; \
        printf '%s  %s\n' "${s6_arch_sha}" /tmp/s6-overlay-arch.tar.xz; \
        printf '%s  %s\n' "${S6_OVERLAY_SYMLINKS_SHA256}" /tmp/s6-overlay-symlinks-noarch.tar.xz; \
    } > /tmp/s6-overlay.sha256; \
    sha256sum -c /tmp/s6-overlay.sha256; \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-overlay-symlinks-noarch.tar.xz; \
    rm /tmp/s6-overlay-*.tar.xz /tmp/s6-overlay.sha256

# #34192 / #66679: backward-compat shim for orchestration templates that
# still reference the legacy /usr/bin/tini entrypoint (Hostinger's
# 'Hermes WebUI' catalog, NAS compose projects that preserve an old
# entrypoint on image update, etc.). A plain symlink to /init made the
# path exist, but forwarded tini flags like `-g` into s6-overlay's
# rc.init as the container CMD (`rc.init: 91: -g: not found`) and
# boot-looped any `restart: unless-stopped` deploy. The shim strips the
# tini CLI surface, then exec's /init + main-wrapper — see
# docker/tini-shim.sh. Safe to drop once the affected catalogs are
# updated.
COPY --chmod=0755 docker/tini-shim.sh /usr/bin/tini

# Non-root user for runtime; UID can be overridden via HERMES_UID at runtime
RUN useradd -u 10000 -m -d /opt/data hermes


WORKDIR /opt/hermes

# ---------- Pinned toolchain from pm/lock.json (single authority) ----------
# The image used to assemble uv from a second authority — an astral image
# tag (ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie) that had already
# drifted to 0.11.6 while pm/lock.json pinned uv 0.12.3. That is exactly
# the two-authorities failure the pm design exists to end. The image is now
# a pin consumer: the stdlib-only pm provisioner reads pm/lock.json and
# stages the pinned uv + full Chromium (sha256-verified at
# download — the same code path pm.sh/pm.ps1 and the desktop payload use)
# into the image's own runtime dir, a self-contained store baked under
# /opt/hermes, outside the /opt/data volume so it survives the overlay.
# PM alone resolves the pinned uv for dependency preparation; build consumers
# receive Python environments, never an installer executable.
#
# Full Chromium supports both headed and headless sessions. It is staged
# here rather than by `npx playwright install`,
# which fetched whatever revision the npm-resolved playwright wanted,
# unverified, and recorded no fact. The resolved browser binary path is
# baked to /etc/hermes/agent-browser-executable-path for stage2-hook.sh:
# the layout differs per arch (chrome-linux64/chrome on amd64,
# chromium-linux-arm64/chromium on arm64), so it is resolved at build time
# and never hunted at boot.
ENV HERMES_RUNTIME_DIR=/opt/hermes/tools
COPY pm/ pm/
# pm's lazy imports resolve get_default_hermes_root()/project_venv_dir()
# from hermes_constants (stdlib-only) at install time — a sealed-stage
# `python3 -m pm.cli install` fails with "No module named
# 'hermes_constants'" without it on the path. Copy the module next to pm.
COPY hermes_constants.py hermes_constants.py
# PM imports the shared stdlib locking owner before deps exist.
COPY hermes_cli/__init__.py hermes_cli/runtime_state.py hermes_cli/
COPY scripts/bundles/payload.py scripts/bundles/payload.py
RUN set -eu; \
    python3 -c 'from pm import ensure; [ensure(name, explicit=True) for name in ("uv", "chromium", "npm", "ffmpeg", "ripgrep")]'; \
    python3 -c 'from pathlib import Path; from pm import installed_package; [Path("/usr/local/bin", command).symlink_to(installed_package(package).binary) for command, package in (("python3", "python"), ("node", "node"), ("npm", "npm"), ("ffmpeg", "ffmpeg"), ("rg", "ripgrep"))]; Path("/usr/local/bin/ffprobe").symlink_to(installed_package("ffmpeg").binary.with_name("ffprobe"))'; \
    ffmpeg -version >/dev/null; ffprobe -version >/dev/null; rg --version >/dev/null; \
    python3 -c 'import shutil; from pathlib import Path; from pm import env_for; Path("/usr/local/bin/npx").symlink_to(shutil.which("npx", path=env_for("npm", base_env={})["PATH"]))'; \
    node --version; npm --version; \
    browser_bin="$(python3 -c 'from pm import installed_package; print(installed_package("chromium").binary)')"; \
    test -n "$browser_bin"; \
    "$browser_bin" --version; \
    mkdir -p /etc/hermes; \
    printf '%s' "$browser_bin" > /etc/hermes/agent-browser-executable-path

# PM is resident too: never borrow application libraries or create its worker
# environment under /root (unreachable to the runtime UID).
RUN python3 -c 'from pathlib import Path; from pm import stage_manager_runtime; from scripts.bundles.payload import seal_pm_runtime; root = Path("/opt/hermes"); python = Path("/usr/local/bin/python3").resolve(); stage_manager_runtime(python=python, destination=root / "pm-runtime", project=root / "pm"); seal_pm_runtime(root, python)'

# JS build helpers use the prepared interpreter without an installer parent.
ENV HERMES_PYTHON=/usr/local/bin/python3
# The standalone interpreter records its builder's clang toolchain;
# native extensions must use the compiler installed in this image.
ENV CC=gcc CXX=g++

FROM runtime_base AS python_deps
# ---------- Layer-cached Python dependency install ----------
# Copy only pyproject.toml + uv.lock so the Python dep resolve + wheel
# download + native-extension compile layer is cached unless those inputs
# change.  Before this split the Python install sat after `COPY . .`, so
# every source-only commit re-did ~4-5 min of dep work on cold builds.
#
# README.md is referenced by pyproject.toml's `readme =` field, but it's
# excluded from the build context by .dockerignore's `*.md`.  uv's build
# frontend stats the readme path during dep resolution, so we `touch` an
# empty placeholder — the real README is restored by `COPY . .` below.
#
# `pm.build_env --no-install-project --extra all --extra messaging --extra otlp`
# installs the deps reachable through the composite `[all]` extra
# (handpicked set intended for the production image; dependency groups are not selected),
# plus gateway messaging adapters that should work in the published image
# without a first-boot lazy install.  We do NOT use `--all-extras`:
# that would pull in `[rl]` (atroposlib + tinker + torch + wandb from
# git) and `[yc-bench]` (another git dep), neither of which belongs in
# the published container.
#
# Provider packages (anthropic, bedrock, azure-identity) are included
# so Docker users can use these providers without requiring runtime
# lazy-install access to PyPI (often blocked in containerized envs).
#
# The [otlp] extra contains the SDK/exporter imported by Hermes when Gateway
# Health export is enabled. Collector and observability-backend dependencies
# remain external and are not part of the Hermes production image.
#
# The Matrix gateway's deps ([matrix] extra) are baked in because
# python-olm (transitive via mautrix[encryption]) builds from source on
# Python/image combinations without usable wheels.  The Docker image is
# Linux-only, so keeping the native libolm/build-toolchain packages here
# avoids the cross-platform failures that kept [matrix] out of [all]
# while still making Matrix work in the published container. Fixes #30399.
#
# Google Chat's [google-chat] extra (google-cloud-pubsub + Chat API clients)
# is baked so hosted/immutable images can enable the adapter without writing
# the sealed venv.
#
# --record-selection writes these extras to the store's facts.json as the venv
# selection, as a bundle build does. Without it, the first opt-in extra a
# container installs on use (FAL, a plugin's deps) records a selection of
# just that extra, and every later boot runs a generation without the extras
# baked here (aiohttp, so no API server). stage2's dependency refresh
# restores this baseline into volumes that already lost it.
#
# Source binding is created after the source copy below.
COPY pyproject.toml uv.lock ./
RUN touch ./README.md
RUN python3 -m pm.build_env --source /opt/hermes --python /usr/local/bin/python3 \
    --out /opt/hermes/.venv --no-install-project --sealed --record-selection \
    --extra all --extra messaging --extra otlp --extra anthropic --extra bedrock \
    --extra azure-identity --extra matrix --extra google-chat

# Icons render on the runtime environment: Pillow and resvg-py are core
# dependencies. A stage of its own so the frontend stage keeps building its
# Node dependencies in parallel with the Python ones.
FROM python_deps AS icons
COPY scripts/generate_icons.py scripts/
COPY assets/ assets/
RUN /opt/hermes/.venv/bin/python -I scripts/generate_icons.py --source /opt/hermes --out /tmp/hermes-icons

# Frontend dependencies never enter the runtime layers.
FROM runtime_base AS frontend_build
COPY package.json package-lock.json ./
COPY web/package.json web/
COPY ui-tui/package.json ui-tui/
COPY ui-tui/packages/hermes-ink/ ui-tui/packages/hermes-ink/
COPY apps/shared/ apps/shared/
COPY scripts/build/node-deps.mjs scripts/build/node-deps.mjs
ENV npm_config_install_links=false
RUN node scripts/build/node-deps.mjs --source /opt/hermes --workspace ui-tui --workspace web

COPY pyproject.toml uv.lock ./
COPY web/ web/
COPY ui-tui/ ui-tui/
COPY scripts/build/*.mjs scripts/build/
COPY scripts/generate-icons.mjs scripts/generate_icons.py scripts/
COPY assets/ assets/
COPY --from=icons /tmp/hermes-icons /tmp/hermes-icons
RUN node scripts/build/tui.mjs --source /opt/hermes --out /opt/products/tui && \
    node scripts/build/web.mjs --source /opt/hermes --icons /tmp/hermes-icons --out /opt/products/web

FROM python_deps AS runtime
# Standalone TypeScript linting is a runtime feature; Vite/esbuild are not.
COPY --from=frontend_build /opt/hermes/node_modules/typescript /opt/hermes/node_modules/typescript
RUN mkdir -p /opt/hermes/node_modules/.bin && \
    ln -s ../typescript/bin/tsc /opt/hermes/node_modules/.bin/tsc

# ---------- Photon iMessage sidecar deps (baked, NS-606) ----------
# The photon plugin's Node sidecar needs its own node_modules
# (spectrum-ts). The install tree is immutable at runtime, so a lazy
# `npm ci` on first connect would hit EROFS — bake the deps here instead
# (deterministic installs, NS-559). The patch script is copied alongside
# the manifests because package.json's postinstall runs it, which also
# means the spectrum-ts patch is applied at build time. Layer-cached:
# only re-runs when the sidecar manifests/patch change.
COPY plugins/platforms/photon/sidecar/package.json \
     plugins/platforms/photon/sidecar/package-lock.json \
     plugins/platforms/photon/sidecar/patch-spectrum-mixed-attachments.mjs \
     plugins/platforms/photon/sidecar/
RUN cd plugins/platforms/photon/sidecar && \
    npm ci --no-audit --fetch-retries=5 && \
    npm cache clean --force

# Shared product outputs are independent of application dependency assembly.
COPY --from=frontend_build /opt/products/tui /opt/hermes/ui-tui
COPY --from=frontend_build /opt/products/web /opt/hermes/hermes_cli/web_dist
# ---------- Bot Screen X socket directory ----------
# Xvnc would create this itself (/tmp is 1777); pre-creating it keeps ownership
# deterministic when HERMES_UID is remapped between boots.
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# XDG_RUNTIME_DIR (set below) sits under a predictable name in world-writable /tmp.
# Shipping it root-owned means stage2 finds a directory it trusts and chowns it.
RUN mkdir -p /tmp/hermes-runtime && chmod 0700 /tmp/hermes-runtime

# ---------- Source code ----------
# .dockerignore excludes node_modules, so the installs above survive.
# --link decouples this layer from parents for cache purposes; --chmod bakes
# the final read-only permissions at copy time so we skip the separate
# `chmod -R` pass that previously walked ~30k files across the venv +
# node_modules + source (21s amd64 / 222s arm64 — #49113).  `a+rX,go-w`
# gives the non-root hermes user read + traverse but no write; root retains
# write so the build steps below don't need chmod u+w dances.
COPY --link --chmod=a+rX,go-w --exclude=opc . .

# The shared assembler binds the prepared environment and frontend products.
RUN /opt/hermes/.venv/bin/python -m docker.build_agent

# Wire the exec shim and install-method stamp.  Files under /opt/hermes are
# already root-owned (COPY, dep assembly, npm install all run as root) and
# read-only for the hermes user (go-w from the --chmod above).

USER root
RUN mkdir -p /opt/hermes/bin && \
    cp /opt/hermes/docker/hermes-exec-shim.sh /opt/hermes/bin/hermes && \
    chmod 0755 /opt/hermes /opt/hermes/bin/hermes && \
    printf 'docker\n' > /opt/hermes/.install_method
# The ``.install_method`` stamp is baked next to the running code (the install
# tree), NOT into $HERMES_HOME. $HERMES_HOME (/opt/data) is a shared data
# volume that is commonly bind-mounted from the host and even shared with a
# host-side Desktop/CLI install; stamping it at boot used to clobber that
# host install's marker and wrongly block its ``hermes update``. A code-scoped
# stamp is read first by detect_install_method() and is immune to the share.
# Start as root so the s6-overlay stage2 hook can usermod/groupmod and chown
# the data volume. Each supervised service then drops to the hermes user via
# `s6-setuidgid hermes` in its run script. If HERMES_UID is unset, services
# run as the default hermes user (UID 10000).

# ---------- Image provenance + install stamp ----------
ARG HERMES_GIT_SHA=71d34bad1045610252eda02ee79549436896e784
RUN python3 scripts/write_install_stamp.py --output /opt/hermes/install-stamp.json \
    --commit "${HERMES_GIT_SHA}" --base-version 0.21.7 --display-version 0.21.7 \
    --distance 0 --source opc --distribution docker --update-mechanism external \
    --runtime-dir tools
# The stamp is code-scoped; the immutable-image marker is outside both the
# install tree and mutable home. Neither can be clobbered by a home mount.
RUN python3 -c 'import json; from pathlib import Path; path = Path("/opt/hermes/install-stamp.json"); stamp = json.loads(path.read_text()); stamp["pmRuntime"] = "/opt/hermes/pm-runtime"; path.write_text(json.dumps(stamp) + "\n"); marker = Path("/etc/hermes/image-provenance.json"); marker.parent.mkdir(parents=True, exist_ok=True); marker.write_text(json.dumps({"schema":1,"deployment_kind":"image","manager":"docker","image":"opc/hermes","version":"0.21.7","revision":stamp["commit"]}) + "\n"); marker.chmod(0o444)'

# ---------- s6-overlay service wiring ----------
# Static services declared at build time: main-hermes + dashboard.
# Per-profile gateway services are registered dynamically at runtime by
# the profile create/delete hooks (Phase 4); they live under
# /run/service/ (tmpfs) and are reconciled on container restart by
# /etc/cont-init.d/02-reconcile-profiles (Phase 4 Task 4.0).
COPY docker/s6-rc.d/ /etc/s6-overlay/s6-rc.d/

# stage2-hook handles UID/GID remap, volume chown, config seeding,
# skills sync — all the work the old entrypoint.sh did before
# `exec hermes`. Wired in as cont-init.d/01- so it
# runs before user services start.
#
# 02-reconcile-profiles re-creates per-profile gateway s6 service
# slots from $HERMES_HOME/profiles/<name>/ after a container restart
# (the /run/service/ scandir is tmpfs and wiped on restart). Phase 4.
RUN mkdir -p /etc/cont-init.d && \
    printf '#!/command/with-contenv sh\nexec /opt/hermes/docker/stage2-hook.sh\n' \
        > /etc/cont-init.d/01-hermes-setup && \
    chmod +x /etc/cont-init.d/01-hermes-setup
COPY --chmod=0755 docker/cont-init.d/015-supervise-perms /etc/cont-init.d/015-supervise-perms
COPY --chmod=0755 docker/cont-init.d/02-reconcile-profiles /etc/cont-init.d/02-reconcile-profiles

# ---------- Runtime ----------
ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
# Point the TUI launcher at the prebuilt bundle baked at build time (Layer 8:
# `ui-tui && npm run build`). This makes _make_tui_argv take the prebuilt-bundle
# fast path (`node --expose-gc /opt/hermes/ui-tui/dist/entry.js`) and skip the
# _tui_need_npm_install / runtime `npm install` branch entirely — exactly the
# nix/packaged-release path the launcher was designed for.
#
# Why this is required (not just an optimization): the root package-lock.json
# describes the WHOLE monorepo workspace set (root + web + ui-tui + apps/*),
# but the image only installs root/web/ui-tui (apps/* — the desktop app — is
# never `npm install`ed here). So the actualized node_modules permanently
# disagrees with the canonical lock, _tui_need_npm_install() returns True on
# every launch, and the runtime `npm install` it triggers (a) can never
# converge against the partial monorepo and (b) races itself across concurrent
# embedded-chat (/api/pty) connections → ENOTEMPTY → the chat tab dies with a
# 502 / "[session ended]". Pointing at the prebuilt bundle sidesteps the whole
# check. (A separate launcher hardening is tracked independently.)
ENV HERMES_TUI_DIR=/opt/hermes/ui-tui
ENV HERMES_HOME=/opt/data
ENV HERMES_WRITE_SAFE_ROOT=/opt/data
# Preserve OPC's sealed-runtime policy on existing editable volume configs too.
ENV HERMES_DISABLE_LAZY_INSTALLS=1

# Xfce, dbus and the display-allocation lock need one; containers have no logind
# to create /run/user/<uid>. The default fallback ($HOME/.cache) is the /opt/data
# volume, which a host-side install may share — two instances would then contend
# for one lock. Container-scoped instead; seeded 0700 by docker/stage2-hook.sh.
ENV XDG_RUNTIME_DIR=/tmp/hermes-runtime

# `docker exec` privilege-drop shim. When operators run
# `docker exec <c> hermes ...` they default to root, and any file the
# command writes under $HERMES_HOME (auth.json, .env, config.yaml) ends
# up root-owned and unreadable to the supervised gateway (UID 10000).
# The shim lives at /opt/hermes/bin/hermes, sits earliest on PATH, and
# transparently re-exec's the real venv binary via `s6-setuidgid hermes`
# when invoked as root. Non-root callers (supervised processes,
# `--user hermes`, etc.) hit the short-circuit path with no overhead.
# Recursion is impossible because the shim exec's the venv binary by
# absolute path (/opt/hermes/.venv/bin/hermes). See the shim source for
# the opt-out env var (HERMES_DOCKER_EXEC_AS_ROOT=1).
COPY --chmod=0755 docker/hermes-exec-shim.sh /opt/hermes/bin/hermes
COPY --chmod=0755 docker/entrypoint-dispatch.sh /opt/hermes/docker/entrypoint-dispatch.sh

# Pre-s6 entrypoint.sh did `source .venv/bin/activate` which exported
# the venv bin onto PATH; Architecture B's main-wrapper.sh does the
# same for the container's main process, but `docker exec` and our
# cont-init.d scripts don't pass through the wrapper. Expose the venv
# bin globally so `docker exec <container> hermes ...` and any
# subprocess that doesn't activate the venv first still find hermes.
#
# /opt/hermes/bin is prepended ahead of the venv so the privilege-drop
# shim wins PATH resolution. The shim's last act is to exec the venv
# binary by absolute path, so this PATH ordering is transparent to
# every other consumer.
ENV PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/.local/bin:${PATH}"
# PM's atomic writer creates private facts for source installs. In the
# image these are shared, non-secret package metadata, read by UID 10000.
# uv's environment locks are build-only and may be world-writable. Remove
# them after all builds; never relax permissions on mutable PM/home state.
RUN mkdir -p /opt/data && chmod 0644 /opt/hermes/tools/facts.json && \
    rm -f /opt/hermes/.venv/.lock /opt/hermes/pm-runtime/.lock
# Build helpers use system Python above; TUI gateway children need the sealed runtime.
ENV HERMES_PYTHON=/opt/hermes/.venv/bin/python
VOLUME [ "/opt/data" ]

# ---------- OPC stack overlay: nix tool persistence + kanban-off seed ----------
COPY opc/nix-seed.sh /usr/local/bin/opc-nix-seed.sh
COPY opc/opc-mise-seed.sh /usr/local/bin/opc-mise-seed.sh
COPY opc/opc-gh-seed.sh /usr/local/bin/opc-gh-seed.sh
COPY opc/hermes-entrypoint.sh /usr/local/bin/hermes-entrypoint.sh
# Sourced by the entrypoint AND executed as a CLI by tests/scientist.sh
# (one .env parser, two consumers — see the file's header).
COPY opc/opc-env-value.sh /usr/local/bin/opc-env-value.sh
COPY opc/opc-default-env.py /usr/local/lib/opc-default-env.py
# Deterministic Paperclip API/workspace client.
COPY opc/opc-paperclip /usr/local/bin/opc-paperclip
RUN chmod +x /usr/local/bin/opc-nix-seed.sh /usr/local/bin/opc-mise-seed.sh /usr/local/bin/opc-gh-seed.sh /usr/local/bin/hermes-entrypoint.sh /usr/local/bin/opc-env-value.sh /usr/local/bin/opc-paperclip

# memory_tencentdb MemoryProvider (TencentDB Knowledge Plane, PRD v10.1) —
# seeded into $HERMES_HOME/plugins/ at boot by hermes-entrypoint.sh.
COPY opc/memory_tencentdb/ /opt/hermes/memory_tencentdb/

# paperclip-api skill (GitHub integration) — seeded into $HERMES_HOME/skills/
# at boot by hermes-entrypoint.sh.
# Agent identity. SOUL.md is read by AIAgent itself (agent/system_prompt.py
# -> load_soul_md, scoped to the agent's own HERMES_HOME), which is why the
# delegation rule lives here and NOT in config.yaml's agent.system_prompt:
# that key is resolved by class HermesCLI in cli.py, so the ACP lane — the
# one the Buzz front door actually runs — never sees it.
COPY opc/SOUL.md /opt/hermes/SOUL.md
COPY opc/skills/paperclip-api/ /opt/hermes/skills/paperclip-api/

# Expert profile identities. Same contract as SOUL.md above: the image is the
# source of truth and the entrypoint overwrites the volume copy every boot,
# because config.yaml is not a safe place for a rule that must hold (hermes
# migrates it — this repo lost a seeded system_prompt that way).
COPY opc/profiles/ /opt/hermes/profiles/

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
    && usermod -aG nixagents hermes \
    && mkdir -m 0755 /nix
COPY --from=nix-seed /nix-seed /nix-seed
# NOTE: the source path is /usr/local/bin/buzz, not buzz.bin. The frontdoor
# image ships the real binary under the plain name; frontdoor's own
# entrypoint (frontdoor-entrypoint.sh) renames it to buzz.bin and writes a
# wrapper over `buzz` at container *start*, so a fresh `docker build` never
# sees a buzz.bin path to copy from. The pristine image was checked directly
# (docker run --entrypoint sh opc/frontdoor:local -- ls /usr/local/bin/buzz*)
# to confirm this before relying on it.
COPY --from=buzz-cli /usr/local/bin/buzz /usr/local/bin/buzz.bin
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
# (opc-mise-seed.sh); PATH tail keeps the baked node 26 authoritative, and
# /opt/mise/shims on the image PATH tail lets docker exec reach omp/rustc/cargo.
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_CONFIG_DIR=/opt/mise/config

ENTRYPOINT [ "/usr/local/bin/hermes-entrypoint.sh" ]
CMD [ "/opt/hermes/docker/entrypoint-dispatch.sh" ]
