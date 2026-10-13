# OPC stack image for TencentDB-Agent-Memory MemoryProxy (v2.0.2) — adapted
# from the upstream MemoryProxy/Dockerfile.
# OPC entrypoint reconciles /data/config.yaml from env vars on every boot.

# syntax=docker/dockerfile:1

FROM node:22-slim AS deps-builder

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        make \
        g++ \
        ca-certificates \
        patch

WORKDIR /app

RUN npm install -g npm@11 --no-audit --no-fund

COPY package.json package-lock.json ./

RUN --mount=type=cache,id=proxy-npm-cache,target=/root/.npm \
    npm install \
        --no-audit \
        --no-fund

COPY . .

# OPC overlay: attach stable x-opencode-session headers to direct task-draft calls.
# Keep this strict: a TencentDB upstream source drift must stop the image build.
COPY opc/patches/opencode-session-headers.patch /tmp/opencode-session-headers.patch
RUN patch -p1 --fuzz=0 --no-backup-if-mismatch < /tmp/opencode-session-headers.patch \
    && rm -f /tmp/opencode-session-headers.patch \
    && grep -q 'x-opencode-session' src/mem-command/task-draft-generator.ts \
    && grep -q 'sessionId: input.sessionKey' src/routes/session-task.ts

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
