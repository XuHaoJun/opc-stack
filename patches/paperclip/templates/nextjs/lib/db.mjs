// Raw pg pool — Postgres is the source of truth. Parameterised queries only.
import pg from "pg";
import { ensureEnv } from "./env.mjs";

ensureEnv();

if (!process.env.DATABASE_URL) {
  throw new Error("DATABASE_URL is not set — run: devenv provision <key> --with postgres,http");
}

export const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,
});
