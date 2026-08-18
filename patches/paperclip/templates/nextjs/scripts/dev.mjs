// Dev server launcher. Three things here are not optional in this environment:
//
//   1. DEV_PORT wins over PORT. The ambient PORT is 3100 (the Paperclip API),
//      not ours; binding it would collide with the board.
//   2. NODE_ENV is deleted. The harness exports production, under which
//      `next dev` will not behave as a dev server.
//   3. Bind 0.0.0.0. Published-port traffic arrives on the container's eth0,
//      so a loopback-bound server is unreachable from the browser — while the
//      health check, which runs inside the container, still passes.
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

if (existsSync(".env")) {
  for (const line of readFileSync(".env", "utf8").split("\n")) {
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (m) process.env[m[1]] = m[2]; // this lease wins over ambient values
  }
}

const port = process.env.DEV_PORT || process.env.PORT || "3000";
const nextBin = new URL("../node_modules/next/dist/bin/next", import.meta.url).pathname;

delete process.env.NODE_ENV;

const child = spawn(nextBin, ["dev", "--hostname", "0.0.0.0", "--port", port], {
  stdio: "inherit",
  env: process.env,
});
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => child.kill(sig));
}
child.on("exit", (code) => process.exit(code ?? 0));
