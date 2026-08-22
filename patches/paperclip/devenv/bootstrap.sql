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
  s3_bucket    text UNIQUE,          -- NULL = s3 not provisioned
  rabbitmq_vhost text UNIQUE,       -- NULL = rabbitmq not provisioned
  -- HTTP preview ports: a tenant holds the CONTIGUOUS block
  -- [http_port_start, http_port_start + http_port_count).
  -- UNIQUE on the start alone is NOT sufficient to prevent overlap (A at
  -- 21000+3 and B at 21001+1 have different starts but collide), so
  -- allocation takes a table lock — see providers/http.sh. The constraint
  -- stays as a cheap backstop against the degenerate same-start case.
  http_port_start int UNIQUE,       -- NULL = http not provisioned
  http_port_count int NOT NULL DEFAULT 0,
  -- Set by `devenv expose`. Approximates "this lease actually has a service
  -- registered with paperclip" without querying paperclip's database: devenv
  -- only knows what devenv did. Someone editing the workspace config from the
  -- board UI will not show up here — it is a nudge for a forgotten `expose`,
  -- not an audit trail.
  http_exposed_at timestamptz,
  created_by   text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now()
);

-- Existing deployments predate the http columns; CREATE TABLE IF NOT EXISTS
-- above is a no-op for them.
ALTER TABLE devenv_tenant ADD COLUMN IF NOT EXISTS http_port_start int UNIQUE;
ALTER TABLE devenv_tenant ADD COLUMN IF NOT EXISTS http_port_count int NOT NULL DEFAULT 0;
ALTER TABLE devenv_tenant ADD COLUMN IF NOT EXISTS http_exposed_at timestamptz;
ALTER TABLE devenv_tenant ADD COLUMN IF NOT EXISTS s3_bucket text UNIQUE;
ALTER TABLE devenv_tenant ADD COLUMN IF NOT EXISTS rabbitmq_vhost text UNIQUE;

-- Sizes come from pg_database_size(), via a LEFT JOIN on pg_database rather
-- than by name.
--
-- The earlier version called pg_database_size(t.slug) directly and let it
-- raise, on the reasoning that every tenant has a database so a missing one
-- means hand-edited state. That reasoning was wrong in two ways: a lease can
-- legitimately have no postgres at all (`--with http`, or `--with valkey`),
-- and more importantly ONE odd row made the whole view raise, so `devenv list`
-- — the tool you reach for precisely when something looks wrong — stopped
-- working entirely. Fail-loud is right; fail-loud on a single cell, not on the
-- listing. A lease that claims postgres but has no database now reads MISSING.
-- DROP + CREATE rather than CREATE OR REPLACE: replacing a view may only
-- APPEND columns, and grouping the http columns next to valkey_db reads far
-- better than tacking them on the end. Nothing depends on this view (it is
DROP VIEW IF EXISTS devenv_usage;
CREATE VIEW devenv_usage AS
SELECT t.key,
       t.created_by,
       t.created_at,
       t.last_seen_at,
       now() - t.last_seen_at                    AS idle,
       t.providers,
       t.valkey_db,
       t.s3_bucket,
       t.rabbitmq_vhost,
       t.http_port_start,
       t.http_port_count,
       -- Leased a preview port but never ran `devenv expose` — the one cost of
       -- splitting provision and expose into two commands, made visible here.
       (t.http_port_start IS NOT NULL
        AND t.http_exposed_at IS NULL)           AS http_unexposed,
       pg_database_size(d.oid)                   AS pg_bytes,
       CASE
         WHEN d.oid IS NOT NULL          THEN pg_size_pretty(pg_database_size(d.oid))
         WHEN 'postgres' = ANY(t.providers) THEN 'MISSING'
       END                                       AS pg_size
FROM devenv_tenant t
LEFT JOIN pg_database d ON d.datname = t.slug
-- NULLS LAST keeps postgres-less leases (http-only) at the bottom instead of
-- the top, so the view stays "biggest consumers first".
ORDER BY pg_database_size(d.oid) DESC NULLS LAST;
