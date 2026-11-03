"""Outbox delivery tests.

The contract is at-least-once with idempotent consumption, so the properties
worth pinning are: a failed send is never marked delivered, a crash between
send and ack re-sends the *same* event id (the consumer dedupes on it), missing
destinations and private-channel refusals are visible rather than silent, and
nothing stale is dropped into an old thread.
"""

import tempfile
import unittest
from pathlib import Path

from opc_bridge import buzz, config, deliver, events, store


class FakeBuzz:
    def __init__(self):
        self.sent = []
        self.fail_channels: dict[str, str] = {}
        self.fail_next = 0

    def send(self, channel, content, reply_to=None, tags=None):
        if self.fail_next:
            self.fail_next -= 1
            raise buzz.BuzzError("relay", "temporary failure")
        if channel in self.fail_channels:
            raise buzz.BuzzError(self.fail_channels[channel], "restricted")
        self.sent.append({"channel": channel, "content": content, "reply_to": reply_to, "tags": tags})
        return buzz.SendResult(event_id="buzz-" + str(len(self.sent)), accepted=True)


def _event(event_id="evt_1", **overrides):
    fields = dict(
        schema_version=1,
        event_id=event_id,
        event_type=events.ISSUE_COMPLETED,
        source="paperclip",
        company_id="c1",
        project_id="p1",
        issue_id="i1",
        issue_identifier="OPC-1",
        issue_title="Build the thing",
        run_id=None,
        status="done",
        occurred_at="2026-11-04T01:00:00Z",
        observed_at="2026-11-04T01:00:00Z",
        artifact_url=None,
        origin_channel_id="origin-uuid",
        origin_event_id="a" * 64,
        correlation_id="OPC-1-done",
        track="core",
    )
    fields.update(overrides)
    return events.Event(**fields)


class DelivererTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.cfg = config.load({"OPC_DB_PATH": str(Path(tmp.name) / "b.db")})
        self.store = store.Store(self.cfg.db_path)
        self.addCleanup(self.store.close)
        self.buzz = FakeBuzz()
        self.now = config.parse_iso("2026-11-04T01:00:00Z") + 60
        self.d = deliver.Deliverer(
            self.cfg, self.store, self.buzz, clock=lambda: self.now, log=lambda *_: None
        )

    def enqueue(self, event=None):
        self.assertTrue(self.store.enqueue_event(event or _event(), self.now))

    # ── state machine ────────────────────────────────────────────────────
    def test_success_marks_sent_with_the_buzz_event_id(self):
        self.enqueue()
        self.assertEqual(self.d.run_once(), 1)

        row = self.store.delivery("evt_1")
        self.assertEqual(row["state"], "sent")
        self.assertEqual(row["buzz_event_id"], "buzz-1")
        self.assertEqual(self.buzz.sent[0]["tags"]["opc-event"], "evt_1")

    def test_failed_send_is_retried_not_marked_delivered(self):
        self.enqueue()
        self.buzz.fail_next = 1

        self.assertEqual(self.d.run_once(), 0)
        row = self.store.delivery("evt_1")
        self.assertEqual(row["state"], "pending")
        self.assertEqual(row["attempts"], 1)
        self.assertGreater(row["next_attempt_at"], self.now)

    def test_crash_between_send_and_ack_redelivers_the_same_event_id(self):
        self.enqueue()
        self.store.claim_due(self.now)      # state=sending, process dies
        self.store.recover_inflight()       # restart

        self.d.run_once()

        self.assertEqual(self.buzz.sent[0]["tags"]["opc-event"], "evt_1")

    def test_not_member_falls_back_to_the_fallback_channel(self):
        self.cfg = config.load(
            {"OPC_DB_PATH": str(self.store.path), "OPC_EVENT_FALLBACK_CHANNEL": "fallback-uuid"}
        )
        self.d = deliver.Deliverer(self.cfg, self.store, self.buzz, clock=lambda: self.now, log=lambda *_: None)
        self.buzz.fail_channels["origin-uuid"] = "not_member"
        self.enqueue()

        self.d.run_once()

        row = self.store.delivery("evt_1")
        self.assertEqual(row["state"], "fallback_sent")
        self.assertEqual([s["channel"] for s in self.buzz.sent], ["fallback-uuid"])

    def test_private_channel_without_fallback_is_visible_not_silent(self):
        self.buzz.fail_channels["origin-uuid"] = "not_member"
        self.enqueue()

        self.d.run_once()

        row = self.store.delivery("evt_1")
        self.assertEqual(row["state"], "failed")
        self.assertIn("not_member", row["last_error"])
        self.assertEqual(self.store.audit_rows()[-1]["action"], "delivery_failed")

    def test_no_destination_marks_failed_and_audits(self):
        self.enqueue(_event(origin_channel_id=None))

        self.d.run_once()

        row = self.store.delivery("evt_1")
        self.assertEqual(row["state"], "failed")
        self.assertIn("no_destination", row["last_error"])
        self.assertEqual(self.store.audit_rows()[-1]["action"], "delivery_failed")

    def test_expired_event_is_not_delivered(self):
        self.enqueue(_event(occurred_at="2000-01-01T00:00:00Z"))

        self.d.run_once()

        self.assertEqual(self.store.delivery("evt_1")["state"], "expired")
        self.assertEqual(self.buzz.sent, [])

    def test_exhausted_attempts_mark_failed(self):
        self.enqueue()
        for _ in range(self.cfg.max_attempts):
            self.buzz.fail_next = 1
            self.now += 3600
            self.d.run_once()

        row = self.store.delivery("evt_1")
        self.assertEqual(row["state"], "failed")

    def test_exhausted_attempts_alert_the_fallback_channel(self):
        self.cfg = config.load(
            {"OPC_DB_PATH": str(self.store.path), "OPC_EVENT_FALLBACK_CHANNEL": "fallback-uuid"}
        )
        self.d = deliver.Deliverer(self.cfg, self.store, self.buzz, clock=lambda: self.now, log=lambda *_: None)
        self.enqueue()
        for _ in range(self.cfg.max_attempts):
            self.buzz.fail_next = 1
            self.now += 3600
            self.d.run_once()

        self.assertEqual(self.store.delivery("evt_1")["state"], "failed")
        self.assertEqual(self.buzz.sent[-1]["channel"], "fallback-uuid")
        self.assertIn("投遞失敗", self.buzz.sent[-1]["content"])

    def test_backoff_grows_and_is_capped(self):
        self.assertEqual(self.d.next_backoff(0), 5)
        self.assertEqual(self.d.next_backoff(1), 10)
        self.assertEqual(self.d.next_backoff(3), 40)
        self.assertEqual(self.d.next_backoff(20), 300)

    def test_delivery_replies_into_the_origin_thread(self):
        self.enqueue()
        self.d.run_once()

        self.assertEqual(self.buzz.sent[0]["reply_to"], "a" * 64)
        self.assertIn("OPC_EVENT: evt_1", self.buzz.sent[0]["content"])
        self.assertIn("Build the thing", self.buzz.sent[0]["content"])


if __name__ == "__main__":
    unittest.main()
