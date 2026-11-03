"""Poller tests: transition detection, baseline, reconcile, backfill.

The poller decides whether anything is emitted at all. Two failure modes are
worth more than the rest: emitting on a baseline (the board gets replayed into
chat on cutover) and failing to emit a second completion of a re-opened ticket
(the dedupe key swallows real work).
"""

import tempfile
import unittest
from pathlib import Path

from opc_bridge import config, events, poller, store


class StubPaperclip:
    def __init__(self):
        self.issues: list[dict] = []
        self.comments_by_issue: dict[str, list[dict]] = {}
        self.runs_by_issue: dict[str, list[dict]] = {}
        self.comment_calls: list[str] = []

    def issues_updated_since(self, iso, limit=100, offset=0):
        rows = [i for i in self.issues if (i.get("updatedAt") or "") > iso]
        return rows[offset : offset + limit]

    def issues_with_status(self, status, limit=100):
        return [i for i in self.issues if i.get("status") == status][:limit]

    def comments(self, issue_id, limit=500):
        self.comment_calls.append(issue_id)
        return self.comments_by_issue.get(issue_id, [])

    def runs_for_issue(self, issue_id):
        return self.runs_by_issue.get(issue_id, [])

    def company(self):
        return "c1"


def _issue(issue_id="i1", identifier="OPC-1", status="todo", updated="2026-11-04T00:00:00Z", **extra):
    row = {"id": issue_id, "identifier": identifier, "status": status, "updatedAt": updated}
    row.update(extra)
    return row


class PollerTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.cfg = config.load(
            {"OPC_DB_PATH": str(Path(tmp.name) / "b.db"), "OPC_EVENT_CUTOVER_LOOKBACK_HOURS": "0"}
        )
        self.store = store.Store(self.cfg.db_path)
        self.addCleanup(self.store.close)
        self.pc = StubPaperclip()
        # Pin "now" near the fixture timestamps: reconcile's window is relative
        # to it, and a 2027 clock silently excludes 2026 issues.
        self.now = poller.parse_iso("2026-11-04T02:00:00Z")
        self.p = poller.Poller(self.cfg, self.store, self.pc, clock=lambda: self.now, log=lambda *_: None)

    # ── baseline ─────────────────────────────────────────────────────────
    def test_bootstrap_seeds_open_issues_and_stays_silent(self):
        self.pc.issues = [
            _issue("i1", status="todo", updated="2026-11-04T00:00:00Z"),
            _issue("i2", status="done", updated="2026-11-04T00:00:00Z", completedAt="2026-11-04T00:00:00Z"),
        ]

        self.p.bootstrap()

        self.assertEqual(self.store.count_deliveries(), 0)
        self.assertIsNotNone(self.store.cursor())
        self.assertEqual(self.store.get_issue_state("i1")["status"], "todo")
        self.assertIsNone(self.store.get_issue_state("i2"))

    def test_first_terminal_observation_without_state_is_silent(self):
        self.p.bootstrap()
        self.store.set_cursor("2026-11-04T00:00:00Z")
        self.pc.issues = [
            _issue("i9", status="done", updated="2026-11-04T01:00:00Z", completedAt="2026-11-04T01:00:00Z")
        ]

        self.assertEqual(self.p.tick(), 0)

    # ── transitions ──────────────────────────────────────────────────────
    def test_terminal_transition_enqueues_exactly_one_event(self):
        self.p.bootstrap()
        self.store.upsert_issue_state(_issue("i1", status="in_progress", updated="2026-11-04T00:00:00Z"))
        self.store.set_cursor("2026-11-04T00:00:00Z")
        self.pc.issues = [
            _issue("i1", status="done", updated="2026-11-04T01:00:00Z", completedAt="2026-11-04T01:00:00Z")
        ]

        self.assertEqual(self.p.tick(), 1)
        self.assertEqual(self.p.tick(), 0)

        delivery = self.store.delivery_for_issue("i1")
        self.assertEqual(delivery["state"], "pending")

    def test_reopened_and_recompleted_ticket_emits_a_second_event(self):
        t1, t2, t3 = (
            "2026-11-04T00:00:00Z",
            "2026-11-04T01:00:00Z",
            "2026-11-04T02:00:00Z",
        )
        self.p.bootstrap()
        self.store.upsert_issue_state(_issue("i1", status="done", updated=t1))
        self.store.set_cursor(t1)

        self.pc.issues = [_issue("i1", status="in_progress", updated=t2)]
        self.assertEqual(self.p.tick(), 0)

        self.pc.issues = [_issue("i1", status="done", updated=t3, completedAt=t3)]
        self.assertEqual(self.p.tick(), 1)

        row = self.store.event_for_issue("i1")
        self.assertEqual(row["event_id"], events.issue_event_id("i1", "done", t3))
        self.assertNotEqual(row["event_id"], events.issue_event_id("i1", "done", t1))

    def test_blocked_reassert_emits(self):
        self.p.bootstrap()
        self.store.upsert_issue_state(
            _issue("i1", status="blocked", updated="2026-11-04T00:00:00Z", blockedTransitionAt="T1")
        )
        self.store.set_cursor("2026-11-04T00:00:00Z")
        self.pc.issues = [
            _issue("i1", status="blocked", updated="2026-11-04T01:00:00Z", blockedTransitionAt="T2")
        ]

        self.assertEqual(self.p.tick(), 1)

    def test_cancelled_transition_emits(self):
        self.p.bootstrap()
        self.store.upsert_issue_state(_issue("i1", status="todo", updated="2026-11-04T00:00:00Z"))
        self.store.set_cursor("2026-11-04T00:00:00Z")
        self.pc.issues = [
            _issue("i1", status="cancelled", updated="2026-11-04T01:00:00Z", cancelledAt="2026-11-04T01:00:00Z")
        ]

        self.assertEqual(self.p.tick(), 1)
        row = self.store.event_for_issue("i1")
        self.assertEqual(row["event_type"], "paperclip.issue.cancelled")

    def test_failed_run_on_an_open_issue_emits_once(self):
        self.p.bootstrap()
        self.store.upsert_issue_state(_issue("i1", status="in_progress", updated="2026-11-04T00:00:00Z"))
        self.store.set_cursor("2026-11-04T00:00:00Z")
        self.pc.issues = [
            _issue("i1", status="in_progress", updated="2026-11-04T01:00:00Z")
        ]
        self.pc.runs_by_issue["i1"] = [{"id": "r1", "status": "failed", "error": "boom"}]

        self.assertEqual(self.p.tick(), 1)
        self.assertEqual(self.p.tick(), 0)
        self.assertEqual(self.store.event_for_issue("i1")["event_type"], "paperclip.issue.failed")

    # ── origin ───────────────────────────────────────────────────────────
    def test_origin_markers_only_from_trusted_authors_and_cached(self):
        channel = "11111111-1111-1111-1111-111111111111"
        anchor = "a" * 64
        self.pc.comments_by_issue["i1"] = [
            {"body": f"BUZZ_CHANNEL: {channel}", "authorType": "agent", "authorAgentId": "ff1b35a2"},
            {"body": f"BUZZ_EVENT: {anchor}", "authorType": "agent", "authorAgentId": "ff1b35a2"},
            {"body": "BUZZ_CHANNEL: 22222222-2222-2222-2222-222222222222", "authorType": "system"},
        ]

        self.assertEqual(self.p.resolve_origin("i1"), (channel, anchor))
        self.p.resolve_origin("i1")
        self.assertEqual(self.pc.comment_calls.count("i1"), 1)

    def test_origin_without_markers_is_empty(self):
        self.pc.comments_by_issue["i1"] = [{"body": "hello", "authorType": "user"}]
        self.assertEqual(self.p.resolve_origin("i1"), (None, None))

    # ── recovery ─────────────────────────────────────────────────────────
    def test_reconcile_recovers_a_terminal_issue_missed_while_stopped(self):
        self.pc.issues = [
            _issue("i7", status="done", updated="2026-11-04T01:00:00Z", completedAt="2026-11-04T01:00:00Z")
        ]

        self.assertEqual(self.p.reconcile(), 1)
        self.assertEqual(self.p.reconcile(), 0)

    def test_backfill_is_explicit_and_idempotent(self):
        self.pc.issues = [
            _issue("i8", status="cancelled", updated="2026-11-04T01:00:00Z", cancelledAt="2026-11-04T01:00:00Z")
        ]

        self.assertEqual(self.p.backfill("2026-11-01T00:00:00Z"), 1)
        self.assertEqual(self.p.backfill("2026-11-01T00:00:00Z"), 0)

    # ── artifacts ────────────────────────────────────────────────────────
    def test_artifact_prefers_a_port_url_and_skips_forge_subpaths(self):
        comments = [
            {"body": "see https://github.com/acme/app/pull/12", "authorType": "agent"},
            {"body": "preview http://10.0.0.5:3007/", "authorType": "agent"},
        ]
        self.assertEqual(poller.extract_artifact(comments), "http://10.0.0.5:3007/")

        comments = [{"body": "repo https://github.com/acme/app", "authorType": "agent"}]
        self.assertEqual(poller.extract_artifact(comments), "https://github.com/acme/app")


if __name__ == "__main__":
    unittest.main()
