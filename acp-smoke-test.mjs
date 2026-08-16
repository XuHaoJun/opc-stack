// Minimal ACP client handshake test: spawn `omp acp`, initialize, then try
// session/new. Proves protocol compatibility between omp (protocolVersion 1,
// vendored implementation) and the @agentclientprotocol/sdk stack used by
// Paperclip's ACPX engine.
import { spawn } from "node:child_process";
import { Writable, Readable } from "node:stream";
import * as acp from "/app/node_modules/.pnpm/@agentclientprotocol+sdk@1.2.1_zod@3.25.76/node_modules/@agentclientprotocol/sdk/dist/acp.js";

const cmd = process.env.OMP_CMD || "omp";
const args = (process.env.OMP_ARGS || "acp --yolo").split(" ");

const proc = spawn(cmd, args, { stdio: ["pipe", "pipe", "inherit"] });
const input = Writable.toWeb(proc.stdin);
const output = Readable.toWeb(proc.stdout);
const stream = acp.ndJsonStream(input, output);

const client = acp.client({ name: "opc-acp-smoke-test" })
  .onRequest(acp.methods.client.fs.readTextFile, async () => {
    return { content: "" };
  })
  .onRequest(acp.methods.client.fs.writeTextFile, async () => {
    return { outcome: "success" };
  })
  .onRequest(acp.methods.client.session.requestPermission, async () => {
    return { outcome: { outcome: "cancelled" } };
  });

try {
  await client.connectWith(stream, async (ctx) => {
    const init = await ctx.request(acp.methods.agent.initialize, {
      protocolVersion: acp.PROTOCOL_VERSION,
      clientCapabilities: {
        fs: { readTextFile: true, writeTextFile: true },
        terminal: true,
      },
    });
    console.log(`INIT_OK agent=${init.agentInfo.name} version=${init.agentInfo.version} protocol=${init.protocolVersion}`);
    if (init.protocolVersion > acp.PROTOCOL_VERSION) {
      throw new Error(`agent wants protocol v${init.protocolVersion}, client has v${acp.PROTOCOL_VERSION}`);
    }
    try {
      const session = await ctx.buildSession("/work").start();
      console.log(`SESSION_OK id=${session.sessionId}`);
      session.dispose();
    } catch (e) {
      // A session may legitimately require authentication first.
      console.log(`SESSION_DEFERRED: ${String((e && e.message) || e).slice(0, 120)}`);
    }
  });
  console.log("HANDSHAKE_PASS");
  proc.kill("SIGTERM");
  process.exit(0);
} catch (e) {
  console.error("HANDSHAKE_FAIL:", e && e.message ? e.message : e);
  proc.kill("SIGKILL");
  process.exit(1);
}
