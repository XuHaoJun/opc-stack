# syntax=docker/dockerfile:1.7
#
# OPC podenv — the nested container lease lane's runtime host.
#
# Deliberately does NOT copy the shared nix seed. AGENTS.md records that the
# seed costs one layer per image (`COPY --from=nix-seed /nix-seed /nix-seed`
# is paid per service image, not just once on the shared volume), and nobody
# shells into this container to work: it is a runtime host, not a work
# environment.
#
# Build via compose service `podenv` (context ./patches/podenv) or:
#   docker build -t opc/podenv:local -f patches/podenv/Dockerfile patches/podenv
FROM quay.io/podman/stable@sha256:8923deffca4caa8338b5dd4f553a86736f2aab424a4743827fccce632fecd750

# The socket's access gate is its OWNER uid, which must equal paperclip's
# runtime `node` user. Assert it at BUILD time so an upstream image that
# renumbers its user fails here, loudly, instead of at socket-connect time
# where the symptom is an opaque "permission denied" from a CLI that looks
# like it should work.
#
# This does NOT contradict the paperclip Dockerfile's "Unifying the runtime
# UIDs instead was rejected" — that rejected CHANGING an existing image's uid
# (paperclip's 1000 comes from the upstream node base image, and its home
# volumes are owned by the current uids — invariant 3b). This is a brand new
# image with no existing volume, aligning itself to the established 1000.
RUN test "$(id -u podman)" = "1000" \
    || { echo "ERROR: podman uid is $(id -u podman), expected 1000 (paperclip's node uid)"; exit 1; }

# Minimal-diff override — see the file's own header for what must not change.
COPY containers.conf /etc/containers/containers.conf

COPY opc-podenv-entrypoint.sh /usr/local/bin/opc-podenv-entrypoint.sh
COPY opc-podenv-restore.sh /usr/local/bin/opc-podenv-restore.sh
RUN chmod +x /usr/local/bin/opc-podenv-entrypoint.sh /usr/local/bin/opc-podenv-restore.sh

ENTRYPOINT ["/usr/local/bin/opc-podenv-entrypoint.sh"]
