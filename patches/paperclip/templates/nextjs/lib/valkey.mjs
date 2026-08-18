// Valkey (redis protocol) client for caching, counters and pub/sub.
import Redis from "ioredis";
import { ensureEnv } from "./env.mjs";

ensureEnv();

if (!process.env.VALKEY_URL) {
  throw new Error("VALKEY_URL is not set — run: devenv provision <key> --with valkey");
}

export const valkey = new Redis(process.env.VALKEY_URL, {
  maxRetriesPerRequest: 2,
  // The tenant ACL denies INFO (it is in the admin category) and ioredis's
  // ready check calls INFO, so the client would never report ready. Errors
  // surface on the individual commands instead, which is what we want anyway.
  enableReadyCheck: false,
});
