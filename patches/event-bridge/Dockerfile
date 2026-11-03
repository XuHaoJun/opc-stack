# OPC Event Bridge
#
# Deterministic integration between Paperclip (work) and Buzz (conversation):
# issue/run transitions become versioned events, an outbox delivers them as the
# `paperclip` identity, and the same process owns policy, admission and health.
#
# The base is the frontdoor image on purpose. It already carries python3 (with
# stdlib sqlite3), the `buzz` CLI, jq and curl — the exact tools this service
# shells out to. A slimmer base would either re-install them (two buzz CLI
# versions to keep in sync) or break the moment the CLI's JSON output changes.
#
# `frontdoor` is a named build context (docker-compose.yml: `service:frontdoor`)
# and is referenced directly here, so compose builds that image first and hands
# it over — no registry lookup, no race on a clean machine (`depends_on` orders
# containers, not builds).
#
# The stage alias must NOT be `frontdoor`: a named context shadows a
# same-named stage, and the shadowed stage's instructions are dropped. Measured
# while building this file — `FROM ${IMAGE} AS frontdoor` produced an image
# whose WorkingDir/Entrypoint were still the base image's, with no error.
# Keeping the alias distinct is what makes the COPY/ENTRYPOINT below take
# effect. A manual build needs the context too:
#   docker build --build-context frontdoor=docker-image://opc/frontdoor:local \
#     -t opc/event-bridge:local patches/event-bridge
FROM frontdoor AS base

WORKDIR /opt/opc-bridge

# The unit suite is baked in so `tests/event-bridge.sh` can run it inside the
# image without a host mount, against the same python3/sqlite3 the service uses.
COPY opc_bridge/ ./opc_bridge/
COPY tests/ ./tests/

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

ENTRYPOINT ["python3", "-m", "opc_bridge.main"]
