# syntax=docker/dockerfile:1.7
#
# OPC stack image for Buzz — adapted from the upstream ghcr.io/block/buzz
# Dockerfile (tag desktop-v0.5.14). Changes vs upstream:
#   1. Also builds `buzz-acp` and the `buzz` CLI so a companion container can
#      bridge the relay to an ACP agent (Hermes front door).
#   2. Runs as root inside the container (self-hosted, host-isolated; the
#      container still has no privileged access to the host).
#   3. Adds a single-user Nix installation whose store lives on the /nix
#      volume: OS-level tools installed with `nix profile install` survive
#      `docker compose down`/`up` and container recreation.
#
# Targets:
#   opc-relay     — the Buzz relay (Postgres + Redis + S3-backed media)
#   opc-frontdoor — buzz-acp + buzz CLI + Hermes Agent CLI (ACP) in one box

ARG RUST_VERSION=1.95
ARG NODE_VERSION=24
ARG DEBIAN_VERSION=bookworm

ARG EXTRA_CA_CERTS=
ARG NPM_REGISTRY=

# ─── Stage 1: cargo-chef base ───────────────────────────────────────────────
FROM rust:${RUST_VERSION}-${DEBIAN_VERSION} AS chef
ARG EXTRA_CA_CERTS
COPY --chmod=0644 ${EXTRA_CA_CERTS:-Dockerfile} /tmp/extra-ca/src
RUN if [ -n "${EXTRA_CA_CERTS}" ]; then \
        cp /tmp/extra-ca/src /usr/local/share/ca-certificates/extra-proxy-ca.crt \
        && update-ca-certificates \
        && echo "CARGO_HTTP_CAINFO=/etc/ssl/certs/ca-certificates.crt" >> /etc/environment; \
    fi
ENV CARGO_HTTP_CAINFO=/etc/ssl/certs/ca-certificates.crt
RUN cargo install cargo-chef --locked --version 0.1.71
WORKDIR /build

# ─── Stage 2: plan dependency graph ─────────────────────────────────────────
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ─── Stage 3: cook dependencies, then build the binaries ────────────────────
FROM chef AS builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libssl-dev \
        ca-certificates \
        git \
    && rm -rf /var/lib/apt/lists/*
ENV CARGO_PROFILE_RELEASE_DEBUG=line-tables-only
COPY --from=planner /build/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
RUN cargo build --release --locked -p buzz-relay --bin buzz-relay \
                                   -p buzz-admin --bin buzz-admin \
                                   -p buzz-pair-relay --bin buzz-pair-relay \
                                   -p buzz-acp --bin buzz-acp \
                                   -p buzz-cli --bin buzz

FROM builder AS stripped-binaries
RUN strip target/release/buzz-relay \
    && strip target/release/buzz-admin \
    && strip target/release/buzz-pair-relay \
    && strip target/release/buzz-acp \
    && strip target/release/buzz

# ─── Stage 4: web bundle (pnpm + vite) ──────────────────────────────────────
FROM node:${NODE_VERSION}-${DEBIAN_VERSION}-slim AS web-builder
WORKDIR /build
ARG EXTRA_CA_CERTS
COPY --chmod=0644 ${EXTRA_CA_CERTS:-Dockerfile} /tmp/extra-ca/src
RUN if [ -n "${EXTRA_CA_CERTS}" ]; then \
        apt-get update && apt-get install -y --no-install-recommends ca-certificates \
        && cp /tmp/extra-ca/src /usr/local/share/ca-certificates/extra-proxy-ca.crt \
        && update-ca-certificates \
        && rm -rf /var/lib/apt/lists/*; \
    fi
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
ARG NPM_REGISTRY
ENV COREPACK_NPM_REGISTRY=${NPM_REGISTRY}
RUN if [ -n "${NPM_REGISTRY}" ]; then \
        echo "registry=${NPM_REGISTRY}" > /build/.npmrc \
        && echo "COREPACK_INTEGRITY_KEYS=0" >> /etc/environment; \
    fi
ENV COREPACK_INTEGRITY_KEYS=${NPM_REGISTRY:+0}
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY patches/ patches/
COPY web/package.json web/
COPY admin-web/package.json admin-web/
RUN pnpm install --frozen-lockfile --filter buzz-web --filter buzz-admin-web
COPY web/ web/
COPY admin-web/ admin-web/
RUN pnpm -C web build && pnpm -C admin-web build

# ─── Stage 5: shared runtime ────────────────────────────────────────────────
FROM debian:${DEBIAN_VERSION}-slim AS runtime-base

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        openssl \
        xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1000 buzz \
    && useradd  --system --uid 1000 --gid 1000 --home-dir /var/lib/buzz \
                --create-home --shell /usr/sbin/nologin buzz

COPY --from=web-builder /build/web/dist                 /srv/buzz/web
COPY --from=web-builder /build/admin-web/dist           /srv/buzz/admin-web

ENV BUZZ_WEB_DIR=/srv/buzz/web \
    BUZZ_ADMIN_WEB_DIR=/srv/buzz/admin-web

EXPOSE 3000 8080 9102

RUN mkdir -p /data/git && chown buzz:buzz /data/git

# ─── Stage 6: relay + tooling image (OPC) ───────────────────────────────────
FROM runtime-base AS opc-relay
COPY --from=stripped-binaries /build/target/release/buzz-relay /usr/local/bin/buzz-relay
COPY --from=stripped-binaries /build/target/release/buzz-admin /usr/local/bin/buzz-admin
COPY --from=stripped-binaries /build/target/release/buzz-pair-relay /usr/local/bin/buzz-pair-relay
COPY --from=stripped-binaries /build/target/release/buzz-acp /usr/local/bin/buzz-acp
COPY --from=stripped-binaries /build/target/release/buzz /usr/local/bin/buzz
# OPC tooling: nix seed helpers + entrypoints.
COPY opc/nix-seed.sh /usr/local/bin/opc-nix-seed.sh
COPY opc/buzz-entrypoint.sh /usr/local/bin/buzz-entrypoint.sh
COPY opc/frontdoor-entrypoint.sh /usr/local/bin/frontdoor-entrypoint.sh
COPY opc/opc-register-agent.sh /usr/local/bin/opc-register-agent.sh
COPY opc/generate-keys.sh /usr/local/bin/opc-generate-keys.sh
COPY opc/add-member.sh /usr/local/bin/opc-add-member.sh
RUN chmod +x /usr/local/bin/opc-nix-seed.sh /usr/local/bin/buzz-entrypoint.sh \
             /usr/local/bin/frontdoor-entrypoint.sh /usr/local/bin/opc-generate-keys.sh \
             /usr/local/bin/opc-add-member.sh

# Single-user Nix (static binary). The whole /nix tree is duplicated to
# /nix-seed so the empty-volume case can be seeded at first boot.
RUN groupadd -r nixbld \
    && useradd -r -g nixbld -d /var/empty -s /usr/sbin/nologin nixbld1 \
    && gpasswd -a nixbld1 nixbld \
    && mkdir -m 0755 /nix \
    && HOME=/root sh -c 'curl -fsSL https://nixos.org/nix/install -o /tmp/nix-install.sh \
        && sh /tmp/nix-install.sh --no-daemon --yes \
        && rm -f /tmp/nix-install.sh' \
    && mkdir -p /nix/etc/nix \
    && printf 'experimental-features = nix-command flakes\nsandbox = false\naccept-flake-config = true\n' > /nix/etc/nix/nix.conf \
        nix --extra-experimental-features 'nix-command flakes' \
        profile install --profile /nix/var/nix/profiles/per-user/root/profile \
        nixpkgs#ripgrep nixpkgs#jq nixpkgs#fd nixpkgs#htop nixpkgs#bat \
    && cp -a /nix /nix-seed

ENV PATH="/nix/var/nix/profiles/per-user/root/profile/bin:/nix/var/nix/profiles/default/bin:${PATH}" \
    NIX_PROFILES="/nix/var/nix/profiles/default /nix/var/nix/profiles/per-user/root" \
    NIX_USER_CONF_FILES="/nix/etc/nix/nix.conf" \
    NIX_SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"

WORKDIR /var/lib/buzz
ENTRYPOINT ["/usr/local/bin/buzz-entrypoint.sh"]
CMD ["/usr/local/bin/buzz-relay"]

# ─── Stage 7: Buzz front door (buzz-acp + Hermes ACP) ───────────────────────
# Hermes Agent CLI installed from the upstream release tag (v2026.8.13 = 0.20.1;
# PyPI still lags at 0.19.0).
FROM opc-relay AS opc-frontdoor

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv python3-pip git \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/hermes-venv \
    && git clone --depth 1 --branch v2026.8.13 \
        https://github.com/NousResearch/hermes-agent.git /opt/hermes-src \
    && /opt/hermes-venv/bin/pip install --no-cache-dir -e "/opt/hermes-src[acp]" \
    && rm -rf /root/.cache/pip

ENV PATH="/opt/hermes-venv/bin:${PATH}" \
    HERMES_HOME=/opt/data
RUN mkdir -p /opt/data

# memory_tencentdb MemoryProvider (TencentDB Knowledge Plane, PRD v10.1) —
# seeded into $HERMES_HOME/plugins/ at boot by frontdoor-entrypoint.sh.
COPY opc/memory_tencentdb/ /opt/hermes/memory_tencentdb/

ENTRYPOINT ["/usr/local/bin/frontdoor-entrypoint.sh"]
CMD []
