# TencentDB OpenCode Session Headers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every TencentDB direct inference request sent to OpenCode Go carries a stable `x-opencode-session` value without changing requests to unrelated providers.

**Architecture:** Add a small endpoint-gated header helper to the MemoryCore source overlay. Standalone Core calls use the existing per-call `sessionId` and a runner-local fallback; local offload calls receive the current state-manager session through internal request metadata that the remote BackendClient strips before serialization. Server-side offload calls thread the task session into Gateway's manual OpenAI-compatible fetch. Add the same endpoint-gated behavior to the independent MemoryKnowledge LLM client, whose client-local fallback remains stable across its multi-step ingest calls. Patch MemoryProxy's active task-draft generator separately, using the existing proxy session key and one fallback across retries; leave ordinary pass-through forwarding unchanged because it preserves caller-supplied headers. Apply all source overlays with strict `patch --fuzz=0` build steps so upstream drift fails the image build.

**Tech Stack:** TypeScript, Vercel AI SDK `@ai-sdk/openai`/`@ai-sdk/anthropic`, Node HTTP fake server, Docker BuildKit builder stages, Bash regression test.

**Spec:** OpenCode Go requires `x-opencode-session`, stable within a conversation and different across conversations; unrelated OpenAI-compatible endpoints must not receive the vendor-specific header. Repository customizations remain under `patches/`, never in `upstream/`.

## Global Constraints

- Keep TencentDB pinned at the current v2.0.1 submodule commit; do not upgrade `feat/server_team` as part of this fix.
- Modify only `patches/tencentdb-agent-memory/`, `tests/`, and the implementation plan; never edit `upstream/` directly.
- Send the real session identifier when a caller has one; use a stable process/client fallback only when no session identifier exists.
- Do not route TencentDB Core through `tencentdb-proxy` to solve this; that can recurse through the proxy's Core memory calls.
- Preserve the existing remote offload HTTP contract by removing local-only session metadata before BackendClient serializes requests.
- Use strict source patches (`patch -p1 --fuzz=0`) in every affected Docker build path.

---

### Task 1: Add failing wire-level regression harness

**Files:**
- Create: `tests/fixtures/tencentdb-session-header.mjs`
- Create: `tests/tencentdb-session-headers.sh`

**Interfaces:**
- The fixture accepts `core`, `knowledge`, or `proxy` plus the source root, starts a loopback OpenAI-compatible fake server, and asserts the received request headers. Core mode covers the standalone runner, local offload, BackendClient serialization boundary, and Gateway's server-side offload client; proxy mode covers the direct task-draft generator.

- [x] **Step 1: Write the fake-server fixture**

The fixture must:

1. Map the requested `opencode.ai` hostname to loopback through the shell runner.
2. Return a valid `/chat/completions` JSON response with one assistant text choice.
3. In Core mode, call `StandaloneLLMRunner.run` with `sessionId: "conversation-a"`, call it twice with that id, then once with `sessionId: "conversation-b"`; assert headers are respectively `conversation-a`, `conversation-a`, and `conversation-b`.
4. In Core mode, cover local offload calls, assert local-only session metadata is stripped from a remote BackendClient body, assert Gateway's manual `fetch` path sends a stable task session header, and exercise an `OffloadTaskExecutor` timer-shaped task whose session exists only at the task level.
5. In Knowledge mode, call `createLlmClient` and `client.chat`; assert the request has a non-empty `x-opencode-session` header.
6. In proxy mode, call the task-draft generator twice with one session key; assert both direct requests carry that key.
7. Assert an ordinary non-OpenCode base URL receives no `x-opencode-session` header.

- [x] **Step 2: Write the build-and-run shell test**

Run `scripts/prepare.sh`, build:

```bash
docker build --target deps-builder -t "$CORE_IMAGE" -f upstream/tencentdb-agent-memory/MemoryCore/opc/Dockerfile upstream/tencentdb-agent-memory/MemoryCore
docker build --target knowledge-builder -t "$KNOWLEDGE_IMAGE" -f upstream/tencentdb-agent-memory/opc/hub.Dockerfile upstream/tencentdb-agent-memory
docker build --target deps-builder -t "$PROXY_IMAGE" -f upstream/tencentdb-agent-memory/MemoryProxy/opc/proxy.Dockerfile upstream/tencentdb-agent-memory/MemoryProxy
```

Run the fixture in each builder with `--add-host=opencode.ai:127.0.0.1`, mounting the fixture read-only. Fail if any builder exits non-zero.

- [x] **Step 3: Run the harness against the baseline source**

Run the harness before enabling the new overlays (the script always runs `scripts/prepare.sh`, so this baseline run predates the patch files).

```bash
tests/tencentdb-session-headers.sh
```

Recorded RED evidence: FAIL because the current AI SDK provider configurations did not send `x-opencode-session`.

---

### Task 2: Patch MemoryCore and MemoryProxy direct inference paths

**Files:**
- Create: `patches/tencentdb-agent-memory/MemoryCore/patches/opencode-session-headers.patch`
- Modify: `patches/tencentdb-agent-memory/MemoryCore/Dockerfile:107-124`
- Create: `patches/tencentdb-agent-memory/MemoryProxy/patches/opencode-session-headers.patch`
- Modify: `patches/tencentdb-agent-memory/MemoryProxy/proxy.Dockerfile`

**Interfaces:**
- Add `src/utils/opencode-session.ts` with endpoint detection and header construction.
- `StandaloneLLMRunner` consumes `buildOpenCodeHeaders(baseUrl, requestedSessionId, fallbackSessionId)`.
- `callLlm` consumes `CallLlmOpts.sessionId` and optional fallback identity.
- Offload request types carry optional local-only `sessionId`; `BackendClient` strips local metadata before remote POST.
- Offload executor LLM calls carry `sessionId`; Gateway's manual OpenAI-compatible client adds it to the request headers.
- MemoryProxy task-draft generation consumes the caller's session key and one generator-local fallback across retries, gated to `opencode.ai`.

- [x] **Step 1: Add strict source overlay**

The patch must:

1. Add a Core helper that only returns headers when the URL hostname is exactly `opencode.ai`.
2. Preserve a non-empty explicit session id after trimming.
3. Generate a fallback once per runner/client, not once per request.
4. Add `headers` to `createOpenAI` in `StandaloneLLMRunner` using `params.sessionId`.
5. Add `sessionId`/fallback handling to offload `callLlm` and `LocalLlmClient`.
6. Thread `stateManager.ctx.sessionId` into L1, L1.5, and L2 request objects.
7. Strip that field in all three `BackendClient` remote request methods before JSON serialization.
8. Thread the offload task session through `OffloadTaskExecutor` using its canonical task/data extractor (including timer-created top-level sessions), and add the header to Gateway's manual `fetch` path.
9. Patch MemoryProxy's direct task-draft fetch with an exact-host gate, explicit session key propagation from `session-task.ts`, and a single fallback for all retries.

- [x] **Step 2: Apply the patch in the Core Dockerfile**

After `COPY . .`, copy the Core patch from `opc/patches/opencode-session-headers.patch`, apply it with `patch -p1 --fuzz=0`, remove the temporary patch, and assert the helper and provider header callsites exist. Apply the MemoryProxy patch after its `COPY . .` with the same strict settings and assert both the header construction and route propagation callsites.

- [x] **Step 3: Run the focused Core regression**

Run:

```bash
tests/tencentdb-session-headers.sh core
```

Expected: PASS for stable explicit session values, distinct sessions, fallback presence, local offload propagation, BackendClient stripping, Gateway offload headers, and no header on an unrelated endpoint.

---


### Task 3: Patch MemoryKnowledge direct inference path

**Files:**
- Create: `patches/tencentdb-agent-memory/patches/knowledge-opencode-session-headers.patch`
- Modify: `patches/tencentdb-agent-memory/hub.Dockerfile:31-36`

**Interfaces:**
- `RawLlmConfig` accepts optional `sessionId` for future ingest callers without changing required config.
- `createLlmClient` uses the explicit session id or one client-local fallback for both OpenAI and Anthropic providers.

- [x] **Step 1: Add strict Knowledge source overlay**

The patch must add endpoint-gated header construction, extend `RawLlmConfig` with `sessionId?: string`, and pass the resulting headers to both `createOpenAI` and `createAnthropic`.

- [x] **Step 2: Apply the patch in the Hub Dockerfile**

After `COPY MemoryKnowledge/ ./`, copy the patch from `opc/patches/knowledge-opencode-session-headers.patch`, apply it with `patch -p1 --fuzz=0`, remove the temporary patch, and assert the header callsite exists.

- [x] **Step 3: Run the focused Knowledge regression**

Run:

```bash
tests/tencentdb-session-headers.sh knowledge
```

Expected: PASS with a non-empty OpenCode header and no header for an unrelated endpoint.

---

### Task 4: Verify patched images and live stack behavior

**Files:**
- Modify: `tests/tencentdb-session-headers.sh` only if the validated harness needs no-scope fixes.

- [x] **Step 1: Run the complete wire-level regression**

Run `tests/tencentdb-session-headers.sh` and require all three builder paths to pass.

- [x] **Step 2: Build the production TencentDB images**

Run `scripts/prepare.sh` followed by `docker compose build tencentdb-core tencentdb-hub tencentdb-proxy`; require strict patch application and successful image completion.

- [x] **Step 3: Exercise live TencentDB health and connectivity**

Run `tests/connectivity.sh` and `tests/migrations.sh tencentdb` against the existing stack. Confirm no degraded store, all metadata routes non-5xx, and all TencentDB services healthy.

- [x] **Step 4: Inspect the final diff and record verification evidence**

Confirm the diff contains only the plan, patch sources, Docker build hooks, and regression harness; no `upstream/` source edits or moving branch pin.
