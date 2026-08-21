-- podenv control schema. Idempotent — re-applied on every paperclip boot.
--
-- Lives in the SAME database as devenv (devenv_control) so there is one place
-- to look and one `docker compose down -v` story, but in its OWN table.
-- devenv_tenant is one-column-per-provider (valkey_db, http_port_start,
-- http_port_count, http_exposed_at); adding OCI columns there would make
-- devenv's schema carry podenv's concepts, and would duplicate the table-lock
-- machinery http.sh needs for contiguous blocks.
CREATE TABLE IF NOT EXISTS podenv_lease (
  key              text PRIMARY KEY,
  slug             text NOT NULL UNIQUE,
  image            text NOT NULL,
  -- 'pasta' gives the lease its own netns and working -p remapping; 'host'
  -- shares the runtime host's netns and has no remapping at all, so the
  -- lease's container_port must already be collision-free.
  netns            text NOT NULL DEFAULT 'pasta' CHECK (netns IN ('pasta','host')),
  container_port   int  NOT NULL,
  -- UNIQUE is sufficient here, unlike devenv's http_port_start: a podenv lease
  -- holds ONE port, not a contiguous block, so there is no "different starts
  -- that still overlap" case and no table lock is needed. The DB is the
  -- arbiter; concurrent callers race harmlessly and the loser retries.
  host_port        int  NOT NULL UNIQUE,
  -- The .env variable name this lease writes. Never one of
  -- devenv_reserved_env_names (enforced in the CLI).
  env_var          text NOT NULL,
  -- Non-NULL means the caller overrode the route gate: the image family is one
  -- devenv already serves, and this is the reason they gave. Persisted and
  -- listed on purpose — that is what keeps --dedicated from being a rubber
  -- stamp, the same reasoning that keeps `prototype destroy` from having
  -- a --yes flag.
  dedicated_reason text,
  created_by       text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now()
);

-- DROP + CREATE rather than CREATE OR REPLACE: replacing a view may only
-- APPEND columns. Nothing depends on this view (it is rebuilt every boot).
--
-- No disk column: a lease's disk lives in podman's store, which SQL cannot
-- see. `podenv list` prints `podman system df` alongside this.
DROP VIEW IF EXISTS podenv_usage;
CREATE VIEW podenv_usage AS
SELECT key,
       image,
       netns,
       container_port,
       host_port,
       env_var,
       dedicated_reason,
       created_by,
       created_at,
       last_seen_at,
       now() - last_seen_at AS idle
FROM podenv_lease
ORDER BY created_at;
