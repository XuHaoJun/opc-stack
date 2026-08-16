# OPC stack image for TencentDB-Agent-Memory MemoryProxy (v2.0.0) — adapted
# from the upstream MemoryProxy/Dockerfile.
# Changes vs upstream:
#   1. cost-guard is a private file: dependency whose submodule is absent from
#      the public v2.0.0 tag — bake the official stub (passthrough fallback)
#      and an empty lockfile instead, mirroring deploy/dockerhub/publish.sh.
#   2. Entrypoint generates /data/config.yaml from env vars on first boot.

# syntax=docker/dockerfile:1

FROM node:22-slim AS deps-builder

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        make \
        g++ \
        ca-certificates

WORKDIR /app

RUN npm install -g npm@11 --no-audit --no-fund

COPY package.json ./

# cost-guard stub (identical to deploy/dockerhub/publish.sh make_cost_guard_stub).
RUN mkdir -p packages/cost-guard/src \
    && printf '%s\n' \
        '{' \
        '  "name": "@context-proxy/cost-guard",' \
        '  "version": "0.0.0-stub",' \
        '  "description": "Placeholder for the optional cost-guard extension. The proxy falls back to passthrough routing when the real module is absent.",' \
        '  "type": "module",' \
        '  "main": "src/index.js",' \
        '  "exports": { ".": "./src/index.js" },' \
        '  "private": true' \
        '}' \
        > packages/cost-guard/package.json \
    && printf '%s\n' \
        '// Placeholder for the optional @context-proxy/cost-guard extension.' \
        '// src/guard-adapter.ts imports this package dynamically and degrades to' \
        '// passthrough routing when the real implementation is unavailable.' \
        'export const CostGuard = undefined;' \
        'export const setAnalyzerDebug = undefined;' \
        'export const resolveAgentProfile = undefined;' \
        > packages/cost-guard/src/index.js \
    && printf '%s\n' \
        '{' \
        '  "name": "context-proxy",' \
        '  "version": "0.0.0",' \
        '  "lockfileVersion": 3,' \
        '  "requires": true,' \
        '  "packages": {}' \
        '}' \
        > package-lock.json

RUN --mount=type=cache,id=proxy-npm-cache,target=/root/.npm \
    npm install \
        --no-audit \
        --no-fund

COPY . .

FROM node:22-slim AS runtime

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        curl \
        tini \
        ca-certificates

WORKDIR /app

RUN groupadd -r app && useradd -r -g app -u 10001 -m app

COPY --from=deps-builder /app /app

RUN mkdir -p /data/tdai-memory-proxy /data/config /app/logs && \
    chown -R app:app /app /data

USER app

ENV NODE_ENV=production \
    PROXY_DB_PATH=/data/tdai-memory-proxy/proxy.db \
    NODE_OPTIONS="--max-old-space-size=1536"

EXPOSE 8096

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD curl -fsS http://127.0.0.1:8096/health || exit 1

COPY --chmod=0755 opc/proxy-entrypoint.sh /usr/local/bin/proxy-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/proxy-entrypoint.sh"]

CMD []
