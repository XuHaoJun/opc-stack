"""Schema and state-store tests.

These run inside the service image (see tests/event-bridge.sh), so they cover
the sqlite3 build the service actually uses rather than whatever the host has.
"""

import tempfile
import unittest
from pathlib import Path

from opc_bridge import store


class StoreSchemaTest(unittest.TestCase):
    def test_creating_schema_twice_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "a.db"
            first = store.Store(path)
            first.close()

            second = store.Store(path)
            self.addCleanup(second.close)

            self.assertEqual(second.schema_version(), store.SCHEMA_VERSION)
            tables = set(second.table_names())
            self.assertLessEqual(
                {
                    "meta",
                    "cursor",
                    "issue_state",
                    "origin",
                    "events",
                    "deliveries",
                    "run_health",
                    "policies",
                    "mandates",
                    "track_state",
                    "agent_pause_ledger",
                    "control_actions",
                    "auth_uses",
                    "audit",
                },
                tables,
            )

    def test_meta_roundtrip_and_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = store.Store(Path(tmp) / "a.db")
            self.addCleanup(s.close)

            self.assertIsNone(s.get_meta("cursor"))
            s.set_meta("cursor", "2026-11-04T00:00:00Z")
            s.set_meta("cursor", "2026-11-04T01:00:00Z")

            self.assertEqual(s.get_meta("cursor"), "2026-11-04T01:00:00Z")

    def test_reopening_keeps_the_wal_mode_and_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "a.db"
            s = store.Store(path)
            s.set_meta("k", "v")
            s.close()

            again = store.Store(path)
            self.addCleanup(again.close)
            self.assertEqual(again.get_meta("k"), "v")
            self.assertEqual(again.journal_mode(), "wal")
