import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const sourceRoot = process.argv[2] ?? "/app";
const { generateTaskDraft } = await import(
  pathToFileURL(`${sourceRoot}/src/mem-command/task-draft-generator.ts`).href
);
const originalFetch = globalThis.fetch;
const content = JSON.stringify({ title: "Test task", description: "Test description" });

try {
  for (const protocol of ["openai", "anthropic", "responses"]) {
    for (const baseUrl of ["https://opencode.ai/v1", "https://ordinary.example/v1"]) {
      for (const requestedSession of [" draft-conversation ", undefined]) {
        const requests = [];
        globalThis.fetch = async (url, init) => {
          requests.push({ url, headers: new Headers(init.headers), body: JSON.parse(init.body) });
          if (requests.length === 1) return new Response("retry", { status: 503 });
          const event = protocol === "anthropic"
            ? { type: "content_block_delta", delta: { type: "text_delta", text: content } }
            : protocol === "responses"
              ? { type: "response.output_text.delta", delta: content }
              : { choices: [{ delta: { content } }] };
          return new Response(`data: ${JSON.stringify(event)}\n\ndata: [DONE]\n\n`, {
            headers: { "content-type": "text/event-stream" },
          });
        };
        const result = await generateTaskDraft({
          enabled: true,
          model: "test-model",
          url: baseUrl,
          apiKey: "test-key",
          timeoutMs: 5_000,
          protocol,
        }, {
          mode: "create",
          sessionId: requestedSession,
          recentMessages: [{ role: "user", content: "draft a task" }],
        });
        assert.equal(result.ok, true, `${protocol}: streaming draft succeeds after retry`);
        assert.equal(requests.length, 2);
        const session = requests[0].headers.get("x-opencode-session");
        if (baseUrl.includes("opencode.ai")) {
          if (requestedSession) assert.equal(session, "draft-conversation");
          else assert.match(session ?? "", /^[0-9a-f-]{36}$/);
          assert.equal(requests[1].headers.get("x-opencode-session"), session);
        } else {
          for (const request of requests) assert.equal(request.headers.get("x-opencode-session"), null);
        }
        for (const request of requests) {
          assert.equal(request.body.stream, true);
          assert.equal("sessionId" in request.body, false);
          assert.equal("fallbackSessionId" in request.body, false);
          assert.equal(request.headers.get("authorization"), "Bearer test-key");
        }
        if (protocol === "anthropic") {
          assert.equal(requests[1].headers.get("anthropic-version"), "2023-06-01");
          assert.equal(requests[1].headers.get("x-api-key"), "test-key");
        }
      }
    }
  }
  console.log("PASS draft protocols: session affinity survives streaming retries without body leakage");
} finally {
  globalThis.fetch = originalFetch;
}
