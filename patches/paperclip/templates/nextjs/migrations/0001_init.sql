-- First migration. Replace this with your own schema — it exists so the
-- migration runner has something to apply and you can see it working.
--
-- schema_migrations is created by scripts/migrate.mjs; do not declare it here.

CREATE TABLE IF NOT EXISTS example (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  note       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
