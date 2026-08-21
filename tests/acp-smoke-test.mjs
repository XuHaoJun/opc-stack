// Minimal ACP client handshake test: spawn `omp acp`, initialize, then try
// session/new. Proves protocol compatibility between omp (protocolVersion 1,
// vendored implementation) and the @agentclientprotocol/sdk stack used by
// Paperclip's ACPX engine.
import { spawn } from "node:child_process";
import { Writable, Readable } from "node:stream";
import { readdirSync } from "node:fs";

// Resolve the SDK out of Paperclip's pnpm store at runtime. The store path
// carries the resolved zod peer in its directory name
// (@agentclientprotocol+sdk@<v>_zod@<v>), so any paperclip bump rewrites it —
// a hard-coded path silently rots into ERR_MODULE_NOT_FOUND and the gate reads
// as "omp broke ACP" when nothing about omp changed. Prefer the highest sdk
// version present; the ACP surface used below is stable across 1.x.
const PNPM_ROOT = process.env.ACP_SDK_PNPM_ROOT || "/app/node_modules/.pnpm";
const sdkDir = readdirSync(PNPM_ROOT)
  .filter((d) => d.startsWith("@agentclientprotocol+sdk@"))
  .sort()
  .pop();
if (!sdkDir) {
  console.error(`HANDSHAKE_FAIL: no @agentclientprotocol/sdk under ${PNPM_ROOT}`);
  process.exit(1);
}
const acpEntry = `${PNPM_ROOT}/${sdkDir}/node_modules/@agentclientprotocol/sdk/dist/acp.js`;
console.log(`SDK ${sdkDir}`);
const acp = await import(acpEntry);

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
