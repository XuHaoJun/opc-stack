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

    # ── cursor / issue state ─────────────────────────────────────────────
    def cursor(self) -> str | None:
        with self._lock:
            row = self._db.execute(
                "SELECT updated_since FROM cursor WHERE id = 1"
            ).fetchone()
        return None if row is None or not row["updated_since"] else str(row["updated_since"])

    def bootstrap_at(self) -> str | None:
        with self._lock:
            row = self._db.execute(
                "SELECT bootstrapped_at FROM cursor WHERE id = 1"
            ).fetchone()
        return None if row is None or not row["bootstrapped_at"] else str(row["bootstrapped_at"])

    def set_cursor(self, updated_since: str, bootstrapped_at: str | None = None) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO cursor(id, updated_since, bootstrapped_at) VALUES(1, ?, ?) "
                "ON CONFLICT(id) DO UPDATE SET updated_since = excluded.updated_since,"
                " bootstrapped_at = COALESCE(excluded.bootstrapped_at, cursor.bootstrapped_at)",
                (updated_since, bootstrapped_at),
            )
            self._db.commit()

    def get_issue_state(self, issue_id: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM issue_state WHERE issue_id = ?", (issue_id,)
            ).fetchone()
        return None if row is None else dict(row)

    def upsert_issue_state(self, issue: dict) -> None:
        from .events import terminal_ts

        with self._lock:
            self._db.execute(
                "INSERT INTO issue_state"
                "(issue_id, identifier, project_id, status, terminal_ts, track, updated_at)"
                " VALUES(?, ?, ?, ?, ?, ?, ?)"
                " ON CONFLICT(issue_id) DO UPDATE SET"
                "  identifier = excluded.identifier,"
                "  project_id = excluded.project_id,"
                "  status = excluded.status,"
                "  terminal_ts = excluded.terminal_ts,"
                "  updated_at = excluded.updated_at",
                (
                    str(issue["id"]),
                    issue.get("identifier"),
                    issue.get("projectId"),
                    issue.get("status"),
                    terminal_ts(issue),
                    issue.get("track"),
                    str(issue.get("updatedAt") or ""),
                ),
            )
            self._db.commit()

    # ── events / deliveries ──────────────────────────────────────────────
    def enqueue_event(self, event, now: float) -> bool:
        import json

        with self._lock:
            cur = self._db.execute(
                "INSERT OR IGNORE INTO events"
                "(event_id, schema_version, event_type, occurred_at, observed_at,"
                " issue_id, run_id, track, payload, created_at)"
                " VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    event.event_id,
                    event.schema_version,
                    event.event_type,
                    event.occurred_at,
                    event.observed_at,
                    event.issue_id,
                    event.run_id,
                    event.track,
                    json.dumps(event.to_dict(), ensure_ascii=False),
                    now,
                ),
            )
            if cur.rowcount != 1:
                self._db.rollback()
                return False
            self._db.execute(
                "INSERT OR IGNORE INTO deliveries(event_id, state, attempts, next_attempt_at, updated_at)"
                " VALUES(?, 'pending', 0, 0, ?)",
                (event.event_id, now),
            )
            self._db.commit()
            return True

    def count_deliveries(self) -> int:
        with self._lock:
            return int(self._db.execute("SELECT COUNT(*) FROM deliveries").fetchone()[0])

    def event_for_issue(self, issue_id: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM events WHERE issue_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
                (issue_id,),
            ).fetchone()
        return None if row is None else dict(row)

    def delivery_for_issue(self, issue_id: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT d.* FROM deliveries d JOIN events e ON e.event_id = d.event_id"
                " WHERE e.issue_id = ? ORDER BY e.created_at DESC, e.rowid DESC LIMIT 1",
                (issue_id,),
            ).fetchone()
        return None if row is None else dict(row)

    # ── origin ───────────────────────────────────────────────────────────
    def get_origin(self, issue_id: str) -> tuple[str | None, str | None] | None:
        with self._lock:
            row = self._db.execute(
                "SELECT channel_id, event_id FROM origin WHERE issue_id = ?", (issue_id,)
            ).fetchone()
        if row is None:
            return None
        return (row["channel_id"], row["event_id"])

    def set_origin(self, issue_id: str, channel_id: str | None, event_id: str | None, at: str) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO origin(issue_id, channel_id, event_id, resolved_at) VALUES(?, ?, ?, ?)"
                " ON CONFLICT(issue_id) DO UPDATE SET"
                "  channel_id = excluded.channel_id, event_id = excluded.event_id,"
                "  resolved_at = excluded.resolved_at",
                (issue_id, channel_id, event_id, at),
            )
            self._db.commit()

    # ── outbox ───────────────────────────────────────────────────────────
    def delivery(self, event_id: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM deliveries WHERE event_id = ?", (event_id,)
            ).fetchone()
        return None if row is None else dict(row)

    def pending_deliveries(self) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT d.*, e.payload FROM deliveries d JOIN events e ON e.event_id = d.event_id"
                " WHERE d.state = 'pending' ORDER BY d.next_attempt_at"
            ).fetchall()
        return [dict(row) for row in rows]

    def claim_due(self, now: float, limit: int = 50) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT d.event_id, d.attempts, e.payload FROM deliveries d"
                " JOIN events e ON e.event_id = d.event_id"
                " WHERE d.state = 'pending' AND d.next_attempt_at <= ?"
                " ORDER BY d.next_attempt_at LIMIT ?",
                (now, limit),
            ).fetchall()
            ids = [row["event_id"] for row in rows]
            for event_id in ids:
                self._db.execute(
                    "UPDATE deliveries SET state = 'sending', updated_at = ?"
                    " WHERE event_id = ? AND state = 'pending'",
                    (now, event_id),
                )
            self._db.commit()
        return [dict(row) for row in rows]

    def recover_inflight(self) -> int:
        with self._lock:
            cur = self._db.execute(
                "UPDATE deliveries SET state = 'pending' WHERE state = 'sending'"
            )
            self._db.commit()
            return int(cur.rowcount)

    def mark_sent(self, event_id: str, buzz_event_id: str, now: float) -> None:
        self._finish_delivery(event_id, "sent", now, buzz_event_id=buzz_event_id)

    def mark_fallback(self, event_id: str, buzz_event_id: str, now: float) -> None:
        self._finish_delivery(event_id, "fallback_sent", now, buzz_event_id=buzz_event_id)

    def mark_expired(self, event_id: str, now: float) -> None:
        self._finish_delivery(event_id, "expired", now, error="expired")

    def mark_failed(self, event_id: str, reason: str, now: float) -> None:
        self._finish_delivery(event_id, "failed", now, error=reason)

    def _finish_delivery(
        self,
        event_id: str,
        state: str,
        now: float,
        buzz_event_id: str | None = None,
        error: str | None = None,
    ) -> None:
        with self._lock:
            self._db.execute(
                "UPDATE deliveries SET state = ?, buzz_event_id = COALESCE(?, buzz_event_id),"
                " last_error = COALESCE(?, last_error), updated_at = ? WHERE event_id = ?",
                (state, buzz_event_id, error, now, event_id),
            )
            self._db.commit()

    def reschedule(self, event_id: str, next_attempt_at: float, error: str, now: float) -> None:
        with self._lock:
            self._db.execute(
                "UPDATE deliveries SET state = 'pending', attempts = attempts + 1,"
                " next_attempt_at = ?, last_error = ?, updated_at = ? WHERE event_id = ?",
                (next_attempt_at, error, now, event_id),
            )
            self._db.commit()

    def recent_events(self, limit: int = 50) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT e.event_id, e.event_type, e.issue_id,"
                " json_extract(e.payload, '$.issue_identifier') AS issue_identifier,"
                " e.run_id, e.track, e.occurred_at, e.observed_at,"
                " d.state AS delivery_state, d.attempts, d.last_error"
                " FROM events e LEFT JOIN deliveries d ON d.event_id = e.event_id"
                " ORDER BY e.created_at DESC, e.rowid DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [dict(row) for row in rows]

    def event(self, event_id: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM events WHERE event_id = ?", (event_id,)
            ).fetchone()
        return None if row is None else dict(row)

    # ── audit ────────────────────────────────────────────────────────────
    def audit(
        self,
        actor: str,
        action: str,
        target: str | None = None,
        detail: dict | None = None,
        source_event_id: str | None = None,
        at: str | None = None,
    ) -> None:
        import datetime as _dt
        import json

        stamp = at or _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")
        with self._lock:
            self._db.execute(
                "INSERT INTO audit(at, actor, action, target, detail_json, source_event_id)"
                " VALUES(?, ?, ?, ?, ?, ?)",
                (stamp, actor, action, target, json.dumps(detail or {}, ensure_ascii=False), source_event_id),
            )
            self._db.commit()

    def audit_rows(self, limit: int = 50) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM audit ORDER BY id DESC LIMIT ?", (limit,)
            ).fetchall()
        return [dict(row) for row in reversed(rows)]

    # ── policy / mandates ────────────────────────────────────────────────
    def insert_policy(self, row: dict) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO policies(id, scope_kind, scope_id, key, value_json, priority,"
                " created_by, reason, source_event_id, created_at, expires_at, revoked_at)"
                " VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    row["id"], row["scope_kind"], row["scope_id"], row["key"],
                    row["value_json"], row["priority"], row["created_by"], row["reason"],
                    row.get("source_event_id"), row["created_at"], row.get("expires_at"),
                    row.get("revoked_at"),
                ),
            )
            self._db.commit()

    def active_policies(self, now_iso: str) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM policies WHERE revoked_at IS NULL"
                " AND (expires_at IS NULL OR expires_at > ?) ORDER BY priority, created_at DESC",
                (now_iso,),
            ).fetchall()
        return [dict(row) for row in rows]

    def list_policy_count(self) -> int:
        with self._lock:
            return int(self._db.execute("SELECT COUNT(*) FROM policies").fetchone()[0])

    def effective_allocation(self, company_id: str, now_iso: str) -> dict:
        from . import policy

        resolved = policy.effective(self, company_id, None, "lab", now_iso)
        return {
            "core": int(resolved["values"]["allocation.core"]),
            "lab": int(resolved["values"]["allocation.lab"]),
        }

    def revoke_policy(self, policy_id: str, at: str) -> int:
        with self._lock:
            cur = self._db.execute(
                "UPDATE policies SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
                (at, policy_id),
            )
            self._db.commit()
            return int(cur.rowcount)

    def insert_mandate(self, row: dict) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO mandates(id, scope_kind, scope_id, style, track, allowed_json,"
                " restricted_json, followups_allowed, max_followups_per_day, review_policy,"
                " created_by, source_event_id, created_at, expires_at, revoked_at, revoked_by, reason)"
                " VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    row["id"], row["scope_kind"], row["scope_id"], row["style"], row["track"],
                    row["allowed_json"], row["restricted_json"], row["followups_allowed"],
                    row.get("max_followups_per_day"), row["review_policy"], row["created_by"],
                    row.get("source_event_id"), row["created_at"], row.get("expires_at"),
                    row.get("revoked_at"), row.get("revoked_by"), row.get("reason"),
                ),
            )
            self._db.commit()

    def active_mandates(self, now_iso: str) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM mandates WHERE revoked_at IS NULL"
                " AND (expires_at IS NULL OR expires_at > ?) ORDER BY created_at DESC",
                (now_iso,),
            ).fetchall()
        return [dict(row) for row in rows]

    def revoke_mandate(self, mandate_id: str, at: str, by: str) -> int:
        with self._lock:
            cur = self._db.execute(
                "UPDATE mandates SET revoked_at = ?, revoked_by = ?"
                " WHERE id = ? AND revoked_at IS NULL",
                (at, by, mandate_id),
            )
            self._db.commit()
            return int(cur.rowcount)

    def get_mandate(self, mandate_id: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM mandates WHERE id = ?", (mandate_id,)
            ).fetchone()
        return None if row is None else dict(row)

    # ── operator authorizations ──────────────────────────────────────────
    def auth_used(self, event_id: str) -> bool:
        with self._lock:
            row = self._db.execute(
                "SELECT 1 FROM auth_uses WHERE event_id = ?", (event_id,)
            ).fetchone()
        return row is not None

    def use_auth(self, event_id: str, at: str, action: str) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO auth_uses(event_id, used_at, action) VALUES(?, ?, ?)",
                (event_id, at, action),
            )
            self._db.commit()

    # ── control state (filled by tasks 17/19) ────────────────────────────
    def track_state(self, track: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM track_state WHERE track = ?", (track,)
            ).fetchone()
        return None if row is None else dict(row)

    def set_track_state(self, track: str, desired: str, state: str, actor: str, reason: str, source_event_id: str | None, at: str) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO track_state(track, desired, state, changed_by, reason, source_event_id, changed_at)"
                " VALUES(?, ?, ?, ?, ?, ?, ?)"
                " ON CONFLICT(track) DO UPDATE SET desired=excluded.desired, state=excluded.state,"
                " changed_by=excluded.changed_by, reason=excluded.reason,"
                " source_event_id=excluded.source_event_id, changed_at=excluded.changed_at",
                (track, desired, state, actor, reason, source_event_id, at),
            )
            self._db.commit()

    # ── agent pause ledger ───────────────────────────────────────────────
    def ledger_put(self, agent_id: str, track: str, status: str, lifecycle: str, holds: str, event_id: str | None, at: str) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO agent_pause_ledger(agent_id, track, original_status,"
                " original_lifecycle_state, original_holds_json, paused_at, paused_by_event)"
                " VALUES(?, ?, ?, ?, ?, ?, ?)"
                " ON CONFLICT(agent_id) DO UPDATE SET track=excluded.track,"
                " original_status=excluded.original_status,"
                " original_lifecycle_state=excluded.original_lifecycle_state,"
                " original_holds_json=excluded.original_holds_json,"
                " paused_at=excluded.paused_at, paused_by_event=excluded.paused_by_event,"
                " released_at=NULL",
                (agent_id, track, status, lifecycle, holds, at, event_id),
            )
            self._db.commit()

    def ledger_get(self, agent_id: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM agent_pause_ledger WHERE agent_id = ?", (agent_id,)
            ).fetchone()
        return None if row is None else dict(row)

    def ledger_all(self, track: str | None = None) -> list[dict]:
        with self._lock:
            if track is None:
                rows = self._db.execute("SELECT * FROM agent_pause_ledger").fetchall()
            else:
                rows = self._db.execute(
                    "SELECT * FROM agent_pause_ledger WHERE track = ?", (track,)
                ).fetchall()
        return [dict(row) for row in rows]

    def ledger_release(self, agent_id: str, at: str) -> None:
        with self._lock:
            self._db.execute(
                "UPDATE agent_pause_ledger SET released_at = ? WHERE agent_id = ?",
                (at, agent_id),
            )
            self._db.commit()

    # ── run health ───────────────────────────────────────────────────────
    def abnormal_run_health(self) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM run_health WHERE state IN ('slow','suspected_stalled','lost')"
            ).fetchall()
        return [dict(row) for row in rows]

    def run_health(self, run_id: str) -> dict | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM run_health WHERE run_id = ?", (run_id,)
            ).fetchone()
        return None if row is None else dict(row)

    def set_run_health(
        self, run_id: str, state: str, updated_at: float,
        last_notified_at: float | None, notify_count: int, first_abnormal_at: float | None,
        track: str = "unknown",
    ) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO run_health(run_id, track, state, first_abnormal_at,"
                " last_notified_at, notify_count, last_progress_at, updated_at)"
                " VALUES(?, ?, ?, ?, ?, ?, ?, ?)"
                " ON CONFLICT(run_id) DO UPDATE SET state=excluded.state,"
                " first_abnormal_at=COALESCE(run_health.first_abnormal_at, excluded.first_abnormal_at),"
                " last_notified_at=excluded.last_notified_at,"
                " notify_count=excluded.notify_count, updated_at=excluded.updated_at",
                (run_id, track, state, first_abnormal_at, last_notified_at, notify_count,
                 first_abnormal_at, updated_at),
            )
            self._db.commit()
