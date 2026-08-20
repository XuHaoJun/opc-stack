# syntax=docker/dockerfile:1.7
#
# OPC shared nix seed — the ONE place nix gets installed. Produces
# /nix-seed (nix 2.35.2 + 12 pinned tools) which the buzz/hermes/paperclip
# images COPY in. Tool-list changes rebuild ONLY this image; service images
# just re-COPY the layer (seconds).
#
# This image also runs the `nix-daemon` service (see opc-nix-daemon.sh): one
# multi-user daemon owning the single shared `opc-nix` volume, so unprivileged
# agents in EVERY container can install packages. Single-user nix (root-only
# writes) is why they could not before.
#
# omp is NOT here — its bun2nix derivation fails to build in image builds
# (bun isolated-linker EPERM, 334 packages; llm-agents.nix at any rev).
# omp ships via mise: `mise use -g github:can1357/oh-my-pi@17.3.5` (prebuilt
# GitHub release, ~170MB) in opc-mise-seed.sh.
#
# Build via compose service `nix-seed` (context ./patches/nix-seed) or:
#   docker build -t opc/nix-seed:local -f patches/nix-seed/Dockerfile patches/nix-seed

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# nix 2.35.2 — pinned installer URL for reproducible builds.
# nix.conf is written to THREE locations: single-user nix reads
# ~/.config/nix/nix.conf and /etc/nix/nix.conf (NOT /nix/etc/nix/nix.conf —
# that one is only for the runtime volume seed via NIX_USER_CONF_FILES).
RUN groupadd -r nixbld \
    && for i in $(seq 1 8); do \
        useradd -r -g nixbld -d /var/empty -s /usr/sbin/nologin "nixbld$i" \
        && gpasswd -a "nixbld$i" nixbld; \
       done \
    && groupadd -g 3000 nixagents \
    && mkdir -m 0755 /nix \
    && HOME=/root sh -c 'curl -fsSL https://releases.nixos.org/nix/nix-2.35.2/install -o /tmp/nix-install.sh \
        && sh /tmp/nix-install.sh --no-daemon --yes \
        && rm -f /tmp/nix-install.sh' \
    && mkdir -p /nix/etc/nix /etc/nix /root/.config/nix \
    && printf 'experimental-features = nix-command flakes\n' > /nix/etc/nix/nix.conf \
    && printf 'experimental-features = nix-command flakes\nsandbox = false\naccept-flake-config = true\nbuild-users-group = nixbld\nmax-jobs = auto\ntrusted-users = root\n' | tee /etc/nix/nix.conf /root/.config/nix/nix.conf >/dev/null \
    && HOME=/root PATH="/nix/var/nix/profiles/default/bin:$PATH" \
        nix --extra-experimental-features 'nix-command flakes' \
        profile install --profile /nix/var/nix/profiles/per-user/root/profile \
        github:NixOS/nixpkgs/8be7bd0c83f1#ripgrep \
        github:NixOS/nixpkgs/8be7bd0c83f1#jq \
        github:NixOS/nixpkgs/8be7bd0c83f1#fd \
        github:NixOS/nixpkgs/8be7bd0c83f1#htop \
        github:NixOS/nixpkgs/8be7bd0c83f1#bat \
        github:NixOS/nixpkgs/8be7bd0c83f1#just \
        github:NixOS/nixpkgs/8be7bd0c83f1#mise \
        github:NixOS/nixpkgs/8be7bd0c83f1#gh \
        github:NixOS/nixpkgs/8be7bd0c83f1#procps \
        github:NixOS/nixpkgs/8be7bd0c83f1#iproute2 \
        github:NixOS/nixpkgs/8be7bd0c83f1#lsof \
        # postgresql is here for its CLIENT (psql/pg_isready): every devenv
        # tenant — the prototype lane, and now the scientist expert — holds a
        # postgres lease, and operators are told to point a SQL client at it
        # (AGENTS.md: "devenv list (或 SQL client 連 127.0.0.1:5433)"). A
        # client belongs in the seed for that reason alone, independent of
        # any test that happens to exercise it today. nixpkgs has no
        # client-only split, so the server binaries come along too (measured
        # closure ~166MB on disk, no single dependency dominates it — icu4c
        # is ~40MB of that, postgresql itself ~26MB, the rest is curl/openssl/
        # glibc-adjacent libs). That cost lands in the shared `opc-nix` volume
        # AND in every service image, since `COPY --from=nix-seed /nix-seed
        # /nix-seed` bakes the same seed into each image's layers. Nothing
        # starts a postgres here — devenv-pg is the server.
        github:NixOS/nixpkgs/8be7bd0c83f1#postgresql \
    && cp -al /nix /nix-seed

# Two roles, one image:
#   `nix-seed`   (CMD true)                 — one-shot; exists so service
#                                             images can COPY --from the layer.
#   `nix-daemon` (opc-nix-daemon.sh)        — long-running; owns the shared
#                                             opc-nix volume and serves every
#                                             other container over the socket.
COPY opc-nix-daemon.sh /usr/local/bin/opc-nix-daemon.sh
RUN chmod 0755 /usr/local/bin/opc-nix-daemon.sh

CMD ["true"]
