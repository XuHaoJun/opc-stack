#!/usr/bin/env node
import assert from "node:assert/strict";
import http from "node:http";
import { pathToFileURL } from "node:url";

const [mode, sourceRoot] = process.argv.slice(2);
if (!mode || !sourceRoot || !["core", "knowledge", "proxy"].includes(mode)) {
  console.error("usage: tencentdb-session-header.mjs <core|knowledge|proxy> <source-root>");
  process.exit(2);
}

const requests = [];
const backendRequests = [];
const responseContent = mode === "proxy"
  ? JSON.stringify({ title: "Test task", description: "Test description", suggestedStatus: "running" })
  : "test response";
const server = http.createServer(async (req, res) => {
  let body = "";
  for await (const chunk of req) body += chunk;

  if (req.method !== "POST") {
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: "not found" } }));
    return;
  }

  if (req.url?.endsWith("/offload/v1/l1/summarize")) {
    backendRequests.push({ headers: req.headers, body });
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ entries: [] }));
    return;
  }

  if (req.url?.endsWith("/offload/v1/l15/judge")) {
    backendRequests.push({ headers: req.headers, body });
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({
      taskCompleted: false,
      isContinuation: false,
      isLongTask: false,
    }));
    return;
  }

  if (req.url?.endsWith("/offload/v1/l2/generate")) {
    backendRequests.push({ headers: req.headers, body });
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({
      fileAction: "write",
      mmdContent: "",
      replaceBlocks: [],
      nodeMapping: {},
    }));
    return;
  }

  if (req.url?.endsWith("/messages")) {
    requests.push({ headers: req.headers, body });
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({
      id: "msg-session-header-test",
      type: "message",
      role: "assistant",
      model: "test-model",
      content: [{ type: "text", text: responseContent }],
      stop_reason: "end_turn",
      stop_sequence: null,
      usage: { input_tokens: 1, output_tokens: 2 },
    }));
    return;
  }

  if (!req.url?.endsWith("/chat/completions")) {
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: "not found" } }));
    return;
  }
  requests.push({ headers: req.headers, body });
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({
    id: "chatcmpl-session-header-test",
    object: "chat.completion",
    created: 1,
    model: "test-model",
    choices: [{
      index: 0,
      message: { role: "assistant", content: responseContent },
      finish_reason: "stop",
    }],
    usage: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 },
  }));
});

await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", resolve);
});

const address = server.address();
assert(address && typeof address === "object");
const openCodeBaseUrl = `http://opencode.ai:${address.port}/v1`;
const ordinaryBaseUrl = `http://127.0.0.1:${address.port}/v1`;

function sessionHeader(request) {
  const value = request.headers["x-opencode-session"];
  return Array.isArray(value) ? value[0] : value;
}

function assertNoSessionHeader(request, label) {
  assert.equal(sessionHeader(request), undefined, `${label} must not receive x-opencode-session`);
}

try {
  if (mode === "core") {
    const { StandaloneLLMRunner } = await import(
      pathToFileURL(`${sourceRoot}/src/adapters/standalone/llm-runner.ts`).href
    );

    const config = { baseUrl: openCodeBaseUrl, apiKey: "test-key", model: "test-model" };
    const runner = new StandaloneLLMRunner({ config, enableTools: false });
    const run = (sessionId) => runner.run({
      prompt: "return test response",
      systemPrompt: "answer briefly",
      taskId: "session-header-test",
      sessionId,
      timeoutMs: 5_000,
    });

    await run("conversation-a");
    await run("conversation-a");
    await run("conversation-b");
    const fallbackRunner = new StandaloneLLMRunner({ config, enableTools: false });
    await fallbackRunner.run({ prompt: "fallback one", taskId: "fallback-one", timeoutMs: 5_000 });
    await fallbackRunner.run({ prompt: "fallback two", taskId: "fallback-two", timeoutMs: 5_000 });

    assert.equal(requests.length, 5);
    assert.equal(sessionHeader(requests[0]), "conversation-a");
    assert.equal(sessionHeader(requests[1]), "conversation-a");
    assert.equal(sessionHeader(requests[2]), "conversation-b");
    assert.match(sessionHeader(requests[3]) ?? "", /^.+$/);
    assert.equal(sessionHeader(requests[3]), sessionHeader(requests[4]));

    const ordinaryRunner = new StandaloneLLMRunner({
      config: { ...config, baseUrl: ordinaryBaseUrl },
      enableTools: false,
    });
    await ordinaryRunner.run({
      prompt: "ordinary provider",
      taskId: "ordinary-provider",
      sessionId: "conversation-c",
      timeoutMs: 5_000,
    });
    assert.equal(requests.length, 6);
    assertNoSessionHeader(requests[5], "ordinary OpenAI-compatible endpoint");

    const { TdaiGateway } = await import(
      pathToFileURL(`${sourceRoot}/src/gateway/server.ts`).href
    );
    const gateway = Object.create(TdaiGateway.prototype);
    gateway.config = {
      llm: { baseUrl: openCodeBaseUrl, apiKey: "test-key", model: "test-model", provider: "openai" },
    };
    gateway.logger = { debug() {}, warn() {} };
    const gatewayClient = gateway.buildOffloadLlmClient();
    assert(gatewayClient);
    await gatewayClient.chat({
      model: "test-model",
      messages: [{ role: "user", content: "gateway offload" }],
      temperature: 0,
      max_tokens: 16,
      timeoutMs: 5_000,
      sessionId: "offload-conversation",
    });
    await gatewayClient.chat({
      model: "test-model",
      messages: [{ role: "user", content: "gateway offload again" }],
      temperature: 0,
      max_tokens: 16,
      timeoutMs: 5_000,
      sessionId: "offload-conversation",
    });
    assert.equal(requests.length, 8);
    assert.equal(sessionHeader(requests[6]), "offload-conversation");
    assert.equal(sessionHeader(requests[7]), "offload-conversation");
    const { OffloadTaskExecutor } = await import(
      pathToFileURL(`${sourceRoot}/src/offload_server/offload-task-executor.ts`).href
    );
    const timerExecutor = new OffloadTaskExecutor({
      resolveStorage: async () => ({
        readFile: async () => null,
        readdirNames: async () => [],
      }),
      llmClient: gatewayClient,
      stateBackend: {},
      logger: { info() {}, warn() {}, error() {} },
    });
    await timerExecutor.executeOffloadL15({
      id: "timer-l15",
      type: "offload-l15",
      instanceId: "test-instance",
      sessionId: "timer-conversation",
      priority: 0,
      data: { recentMessages: "timer path", boundaryTimestamp: "timer-boundary" },
      createdAt: Date.now(),
    });
    assert.equal(requests.length, 9);
    assert.equal(sessionHeader(requests[8]), "timer-conversation");

    const { callLlm } = await import(
      pathToFileURL(`${sourceRoot}/src/offload/local-llm/llm-caller.ts`).href
    );
    await callLlm(
      {
        baseUrl: openCodeBaseUrl,
        apiKey: "test-key",
        model: "test-model",
        temperature: 0,
        timeoutMs: 5_000,
      },
      {
        systemPrompt: "answer briefly",
        userPrompt: "local offload",
        sessionId: "local-offload",
      },
    );

    const { LocalLlmClient } = await import(
      pathToFileURL(`${sourceRoot}/src/offload/local-llm/index.ts`).href
    );
    const localClient = new LocalLlmClient({
      baseUrl: openCodeBaseUrl,
      apiKey: "test-key",
      model: "test-model",
      timeoutMs: 5_000,
    });
    await localClient.l1Summarize({
      recentMessages: "",
      toolPairs: [],
      sessionId: "local-client",
    });

    const { BackendClient } = await import(
      pathToFileURL(`${sourceRoot}/src/offload/backend-client.ts`).href
    );
    const backendClient = new BackendClient(ordinaryBaseUrl, {});
    await backendClient.l1Summarize({
      recentMessages: "",
      toolPairs: [],
      sessionId: "local-only",
    });
    assert.equal(backendRequests.length, 1);
    assert.equal("sessionId" in JSON.parse(backendRequests[0].body), false);
    await backendClient.l15Judge({
      recentMessages: "",
      currentMmd: null,
      availableMmdMetas: [],
      sessionId: "local-only",
    });
    await backendClient.l2Generate({
      existingMmd: null,
      newEntries: [],
      recentHistory: null,
      currentTurn: null,
      taskLabel: "task",
      mmdPrefix: "000",
      mmdCharCount: 0,
      sessionId: "local-only",
    });
    assert.equal(backendRequests.length, 3);
    for (const request of backendRequests) {
      assert.equal("sessionId" in JSON.parse(request.body), false);
    }

    assert.equal(requests.length, 11);
    assert.equal(sessionHeader(requests[9]), "local-offload");
    assert.equal(sessionHeader(requests[10]), "local-client");
  } else if (mode === "knowledge") {
    const { createLlmClient } = await import(
      pathToFileURL(`${sourceRoot}/src/engines/wiki/ingest-v2/llm.ts`).href
    );

    const client = createLlmClient({
      baseUrl: openCodeBaseUrl,
      apiKey: "test-key",
      model: "test-model",
    });
    await client.chat({ system: "answer briefly", prompt: "first", label: "first" });
    await client.chat({ system: "answer briefly", prompt: "second", label: "second" });

    assert.equal(requests.length, 2);
    assert.match(sessionHeader(requests[0]) ?? "", /^.+$/);
    assert.equal(sessionHeader(requests[0]), sessionHeader(requests[1]));
    const anthropicClient = createLlmClient({
      protocol: "anthropic",
      baseUrl: openCodeBaseUrl,
      apiKey: "test-key",
      model: "test-model",
    });
    await anthropicClient.chat({ system: "answer briefly", prompt: "anthropic", label: "anthropic" });
    assert.equal(requests.length, 3);
    assert.match(sessionHeader(requests[2]) ?? "", /^.+$/);

    const ordinaryClient = createLlmClient({
      baseUrl: ordinaryBaseUrl,
      apiKey: "test-key",
      model: "test-model",
    });
    await ordinaryClient.chat({ system: "answer briefly", prompt: "ordinary", label: "ordinary" });
    assert.equal(requests.length, 4);
    assertNoSessionHeader(requests[3], "ordinary OpenAI-compatible endpoint");
  } else {
    const { generateTaskDraft } = await import(
      pathToFileURL(`${sourceRoot}/src/mem-command/task-draft-generator.ts`).href
    );
    const draftConfig = {
      enabled: true,
      model: "test-model",
      url: openCodeBaseUrl,
      apiKey: "test-key",
      timeoutMs: 5_000,
    };
    const draftInput = {
      mode: "create",
      sessionId: "proxy-conversation",
      recentMessages: [{ role: "user", content: "draft a task" }],
    };
    const firstDraft = await generateTaskDraft(draftConfig, draftInput);
    const secondDraft = await generateTaskDraft(draftConfig, draftInput);
    assert.equal(firstDraft.ok, true);
    assert.equal(secondDraft.ok, true);
    assert.equal(requests.length, 2);
    assert.equal(sessionHeader(requests[0]), "proxy-conversation");
    assert.equal(sessionHeader(requests[1]), "proxy-conversation");

    await generateTaskDraft(
      { ...draftConfig, url: ordinaryBaseUrl },
      draftInput,
    );
    assert.equal(requests.length, 3);
    assertNoSessionHeader(requests[2], "ordinary OpenAI-compatible endpoint");
  }

  console.log(`PASS ${mode}: OpenCode session header is present and stable`);
} finally {
  await new Promise((resolve) => server.close(resolve));
}
