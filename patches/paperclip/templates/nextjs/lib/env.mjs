// Loads .env from the working directory (the prototype root) into process.env.
//
// File values OVERWRITE ambient ones, which is the opposite of most dotenv
// loaders and is deliberate: the harness injects the *execution workspace's*
// devenv lease, which belongs to a different tenant. Preferring the ambient
// value means quietly reading and writing someone else's database — a failure
// with no error message, only wrong data.
//
// Idempotent; safe to call from anywhere.
import { existsSync, readFileSync } from "node:fs";

let loaded = false;

export function ensureEnv() {
  if (loaded) return;
  loaded = true;
  if (!existsSync(".env")) return;
  for (const line of readFileSync(".env", "utf8").split("\n")) {
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (m) process.env[m[1]] = m[2];
  }
}
