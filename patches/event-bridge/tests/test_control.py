"""Operator authorization tests.

Force stop and every policy mutation hang off this. The tests pin the refusals
that matter: a stranger, a stale message, a message whose text is not the
command, and a replay of a valid command.
"""

import tempfile
import unittest
from pathlib import Path

from opc_bridge import buzz, config, control, store

NOW = config.parse_iso("2026-11-04T02:00:00Z")
OPERATOR = "a" * 64


class FakeBuzz:
    def __init__(self):
        self.rows: list[dict] = []

    def messages(self, channel, since=None, limit=200):
        return [row for row in self.rows if int(row.get("created_at") or 0) >= (since or 0)]


class AuthTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.cfg = config.load(
            {
                "OPC_DB_PATH": str(Path(tmp.name) / "c.db"),
                "OPC_OPERATOR_PUBKEY": OPERATOR,
                "OPC_CONTROL_CHANNEL": "chan-1",
            }
        )
        self.store = store.Store(self.cfg.db_path)
        self.addCleanup(self.store.close)
        self.buzz = FakeBuzz()
        self.auth = control.OperatorAuth(self.cfg, self.buzz, self.store, "chan-1", clock=lambda: NOW)

    def sign(self, content, event_id, author=OPERATOR, created_at=None):
        self.buzz.rows.append(
            {
                "id": event_id,
                "pubkey": author,
                "content": content,
                "created_at": int(NOW if created_at is None else created_at),
            }
        )

    def test_valid_command_is_accepted_then_replay_is_rejected(self):
        command = "!opc mandate grant project=p1 track=lab style=exploration"
        self.sign(command, "e" * 64)

        self.auth.verify(command, "e" * 64, now=NOW)
        with self.assertRaises(control.AuthError) as caught:
            self.auth.verify(command, "e" * 64, now=NOW + 1)
        self.assertEqual(caught.exception.reason, "replayed")

    def test_wrong_author_is_rejected(self):
        self.sign("!opc pause lab", "e" * 64, author="f" * 64)
        with self.assertRaises(control.AuthError) as caught:
            self.auth.verify("!opc pause lab", "e" * 64, now=NOW)
        self.assertEqual(caught.exception.reason, "wrong_author")

    def test_command_text_must_match_the_signed_message(self):
        self.sign("!opc pause lab", "e" * 64)
        with self.assertRaises(control.AuthError) as caught:
            self.auth.verify("!opc resume lab", "e" * 64, now=NOW)
        self.assertEqual(caught.exception.reason, "command_mismatch")

    def test_stale_command_is_rejected(self):
        self.sign("!opc pause lab", "e" * 64, created_at=NOW - 1000)
        with self.assertRaises(control.AuthError) as caught:
            self.auth.verify("!opc pause lab", "e" * 64, now=NOW)
        self.assertEqual(caught.exception.reason, "stale")

    def test_missing_event_is_rejected(self):
        with self.assertRaises(control.AuthError) as caught:
            self.auth.verify("!opc pause lab", "e" * 64, now=NOW)
        self.assertEqual(caught.exception.reason, "not_found")

    def test_missing_operator_configuration_fails_closed(self):
        cfg = config.load({"OPC_DB_PATH": str(self.store.path), "OPC_OPERATOR_PUBKEY": ""})
        auth = control.OperatorAuth(cfg, self.buzz, self.store, "chan-1", clock=lambda: NOW)
        self.sign("!opc pause lab", "e" * 64)
        with self.assertRaises(control.AuthError) as caught:
            auth.verify("!opc pause lab", "e" * 64, now=NOW)
        self.assertEqual(caught.exception.reason, "missing")


if __name__ == "__main__":
    unittest.main()
