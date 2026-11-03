"""Sqlite state for the bridge.

This database is bookkeeping and policy — never work truth. Paperclip owns
issues, assignments, runs and their status; this store owns:

  cursor          where the poller is in Paperclip's update stream
  issue_state     last observed status per issue (transition detection)
  origin          the Buzz channel/thread a ticket came from
  events          the versioned contract, one row per event_id (dedupe point)
  deliveries      outbox state machine per event
  run_health      health classification + reminder bookkeeping per run
  policies        operator overrides / adaptive values (policy configuration)
  mandates        scoped autonomy grants
  track_state     core/lab desired vs observed control state
  agent_pause_ledger  which agents we paused, and what to restore
  control_actions every control mutation and its result
  auth_uses       one-time uses of an owner-signed command (replay defence)
  audit           append-only log of every state change

WAL + a single connection guarded by a lock: the process has four threads
(poller, deliverer, health, api) and sqlite's default check_same_thread would
otherwise force either a connection per thread (and lock contention on write)
or no concurrency at all.
"""

from __future__ import annotations

import sqlite3
import threading
from pathlib import Path

SCHEMA_VERSION = 1

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS cursor (
    id            INTEGER PRIMARY KEY CHECK (id = 1),
    updated_since TEXT,
    bootstrapped_at TEXT
);

CREATE TABLE IF NOT EXISTS issue_state (
    issue_id     TEXT PRIMARY KEY,
    identifier   TEXT,
    project_id   TEXT,
    status       TEXT,
    terminal_ts  TEXT,
    track        TEXT,
    updated_at   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS origin (
    issue_id    TEXT PRIMARY KEY,
    channel_id  TEXT,
    event_id    TEXT,
    resolved_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
    event_id       TEXT PRIMARY KEY,
    schema_version INTEGER NOT NULL,
    event_type     TEXT NOT NULL,
    occurred_at    TEXT NOT NULL,
    observed_at    TEXT NOT NULL,
    issue_id       TEXT,
    run_id         TEXT,
    track          TEXT,
    payload        TEXT NOT NULL,
    created_at     REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS deliveries (
    event_id        TEXT PRIMARY KEY REFERENCES events(event_id),
    state           TEXT NOT NULL DEFAULT 'pending',
    attempts        INTEGER NOT NULL DEFAULT 0,
    next_attempt_at REAL NOT NULL DEFAULT 0,
    last_error      TEXT,
    buzz_event_id   TEXT,
    updated_at      REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS deliveries_due_idx ON deliveries(state, next_attempt_at);

CREATE TABLE IF NOT EXISTS run_health (
    run_id            TEXT PRIMARY KEY,
    track             TEXT,
    state             TEXT NOT NULL,
    first_abnormal_at REAL,
    last_notified_at  REAL,
    notify_count      INTEGER NOT NULL DEFAULT 0,
    last_progress_at  REAL,
    updated_at        REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS policies (
    id              TEXT PRIMARY KEY,
    scope_kind      TEXT NOT NULL,
    scope_id        TEXT NOT NULL,
    key             TEXT NOT NULL,
    value_json      TEXT NOT NULL,
    priority        INTEGER NOT NULL,
    created_by      TEXT NOT NULL,
    reason          TEXT NOT NULL,
    source_event_id TEXT,
    created_at      TEXT NOT NULL,
    expires_at      TEXT,
    revoked_at      TEXT
);
CREATE INDEX IF NOT EXISTS policies_scope_idx ON policies(scope_kind, scope_id, key);

CREATE TABLE IF NOT EXISTS mandates (
    id                 TEXT PRIMARY KEY,
    scope_kind         TEXT NOT NULL,
    scope_id           TEXT NOT NULL,
    style              TEXT NOT NULL,
    track              TEXT NOT NULL,
    allowed_json       TEXT NOT NULL,
    restricted_json    TEXT NOT NULL,
    followups_allowed  INTEGER NOT NULL DEFAULT 0,
    max_followups_per_day INTEGER,
    review_policy      TEXT NOT NULL,
    created_by         TEXT NOT NULL,
    source_event_id    TEXT,
    created_at         TEXT NOT NULL,
    expires_at         TEXT,
    revoked_at         TEXT,
    revoked_by         TEXT,
    reason             TEXT
);

CREATE TABLE IF NOT EXISTS track_state (
    track           TEXT PRIMARY KEY,
    desired         TEXT NOT NULL,
    state           TEXT NOT NULL,
    changed_by      TEXT NOT NULL,
    reason          TEXT,
    source_event_id TEXT,
    changed_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS agent_pause_ledger (
    agent_id                TEXT PRIMARY KEY,
    track                   TEXT NOT NULL,
    original_status         TEXT,
    original_lifecycle_state TEXT,
    original_holds_json     TEXT,
    paused_at               TEXT NOT NULL,
    paused_by_event         TEXT,
    released_at             TEXT
);

CREATE TABLE IF NOT EXISTS control_actions (
    id              TEXT PRIMARY KEY,
    at              TEXT NOT NULL,
    action          TEXT NOT NULL,
    target          TEXT,
    actor           TEXT NOT NULL,
    source_event_id TEXT,
    result_json     TEXT
);

CREATE TABLE IF NOT EXISTS auth_uses (
    event_id TEXT PRIMARY KEY,
    used_at  TEXT NOT NULL,
    action   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS audit (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    at              TEXT NOT NULL,
    actor           TEXT NOT NULL,
    action          TEXT NOT NULL,
    target          TEXT,
    detail_json     TEXT,
    source_event_id TEXT
);
"""


class Store:
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._db = sqlite3.connect(
            str(self.path), check_same_thread=False, timeout=30.0
        )
        self._db.row_factory = sqlite3.Row
        with self._lock:
            self._db.execute("PRAGMA journal_mode=WAL")
            self._db.execute("PRAGMA foreign_keys=ON")
            self._db.execute("PRAGMA busy_timeout=30000")
            self._apply_schema()

    # ── lifecycle ────────────────────────────────────────────────────────
    def _apply_schema(self) -> None:
        version = self._db.execute("PRAGMA user_version").fetchone()[0]
        if version >= SCHEMA_VERSION:
            return
        self._db.executescript(_SCHEMA_SQL)
        self._db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        self._db.commit()

    def close(self) -> None:
        with self._lock:
            self._db.close()

    # ── introspection ────────────────────────────────────────────────────
    def schema_version(self) -> int:
        with self._lock:
            return int(self._db.execute("PRAGMA user_version").fetchone()[0])

    def journal_mode(self) -> str:
        with self._lock:
            return str(self._db.execute("PRAGMA journal_mode").fetchone()[0]).lower()

    def table_names(self) -> list[str]:
        with self._lock:
            rows = self._db.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            ).fetchall()
        return [str(row["name"]) for row in rows]

    # ── meta ─────────────────────────────────────────────────────────────
    def set_meta(self, key: str, value: str) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO meta(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, value),
            )
            self._db.commit()

    def get_meta(self, key: str) -> str | None:
        with self._lock:
            row = self._db.execute(
                "SELECT value FROM meta WHERE key = ?", (key,)
            ).fetchone()
        return None if row is None else str(row["value"])
