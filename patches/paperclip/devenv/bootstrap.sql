-- devenv control schema. Idempotent — re-run on every paperclip boot.
-- Lives in the devenv_control database on devenv-pg; the CREATE DATABASE
-- itself is done by opc-devenv-seed.sh (CREATE DATABASE can't run inside a
-- transaction block, and psql -f wraps nothing, so it stays in the shell).

CREATE TABLE IF NOT EXISTS devenv_tenant (
  key          text PRIMARY KEY,
  slug         text NOT NULL UNIQUE,
  lifecycle    text NOT NULL DEFAULT 'keep'
               CHECK (lifecycle IN ('keep','ephemeral')),
  providers    text[] NOT NULL,
  valkey_db    int UNIQUE,          -- NULL = valkey not provisioned
  created_by   text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now()
);

-- Sizes come from pg_database_size(slug). A tenant row always has its
-- database (release deletes both), so a missing database means someone
-- edited state by hand — surface that as an error rather than a wrong
-- number. pg_database_size() raising is the intended fail-loud behaviour.
CREATE OR REPLACE VIEW devenv_usage AS
SELECT t.key,
       t.created_by,
       t.created_at,
       t.last_seen_at,
       now() - t.last_seen_at                    AS idle,
       t.providers,
       t.valkey_db,
       pg_database_size(t.slug)                  AS pg_bytes,
       pg_size_pretty(pg_database_size(t.slug))  AS pg_size
FROM devenv_tenant t
ORDER BY pg_database_size(t.slug) DESC;
