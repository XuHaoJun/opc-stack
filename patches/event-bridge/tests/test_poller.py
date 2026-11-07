"""Poller tests: transition detection, baseline, reconcile, backfill.

The poller decides whether anything is emitted at all. Two failure modes are
worth more than the rest: emitting on a baseline (the board gets replayed into
chat on cutover) and failing to emit a second completion of a re-opened ticket
(the dedupe key swallows real work).
"""

import json
import tempfile
import unittest
from pathlib import Path

from opc_bridge import config, events, poller, store


class StubPaperclip:
    def __init__(self):
        self.issues: list[dict] = []
        self.comments_by_issue: dict[str, list[dict]] = {}
        self.runs_by_issue: dict[str, list[dict]] = {}
        self.runs_recent: list[dict] = []
        self.comment_calls: list[str] = []
        self.label_rows: list[dict] = []
        self.agent_rows: list[dict] = []
        self.patched_issues: list[tuple] = []

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

    def run(self, run_id):
        for rows in self.runs_by_issue.values():
            for row in rows:
                if str(row.get("id") or row.get("runId")) == str(run_id):
                    return row
        return {}

    def heartbeat_runs(self, limit=100):
        return self.runs_recent[:limit]

    def issue(self, issue_id):
        return next(i for i in self.issues if i["id"] == issue_id)

    def company(self):
        return "c1"

    def labels(self):
        return self.label_rows

    def create_label(self, name, color):
        row = {"id": "label-" + name, "name": name}
        self.label_rows.append(row)
        return row

    def patch_issue(self, issue_id, body):
        self.patched_issues.append((issue_id, dict(body)))
        return {"id": issue_id}

    def agents(self):
        return self.agent_rows


def _issue(issue_id="i1", identifier="OPC-1", status="todo", updated="2026-11-04T00:00:00Z", **extra):
    row = {"id": issue_id, "identifier": identifier, "status": status, "updatedAt": updated}
    row.update(extra)
    return row


class PollerTest(unittest.TestCase):
    def setUp(self):
        self.runs_recent = []
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

    def test_terminal_issue_created_after_bootstrap_is_an_event_not_history(self):
        # The live gap this closes: an issue created and completed between two
        # ticks was first observed terminal, and the baseline rule swallowed it.
        # Baseline silence is for history, not for work that happened after the
        # bridge started watching.
        self.p.bootstrap()
        self.store.set_cursor("2026-11-04T02:00:00Z")
        self.pc.issues = [
            _issue(
                "i5",
                identifier="OPC-5",
                status="done",
                updated="2026-11-04T02:05:00Z",
                completedAt="2026-11-04T02:05:00Z",
                createdAt="2026-11-04T02:04:00Z",
            )
        ]

        self.assertEqual(self.p.tick(), 1)

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

    def test_run_sweep_emits_once_for_a_failed_run_on_an_open_issue(self):
        self.store.set_meta("run_sweep_cursor", "2026-11-04T00:00:00Z")
        self.pc.issues = [_issue("i1", status="in_progress", updated="2026-11-04T00:00:00Z")]
        self.pc.runs_recent = [
            {"id": "r1", "runId": None, "status": "failed", "finishedAt": "2026-11-04T01:00:00Z", "issueId": "i1"}
        ]

        self.assertEqual(self.p.tick(), 1)
        self.assertEqual(self.p.tick(), 0)

        row = self.store.event_for_issue("i1")
        self.assertEqual(row["event_type"], "paperclip.issue.failed")
        self.assertEqual(row["event_id"], events.run_event_id("r1", "failed"))
        self.assertEqual(json.loads(row["payload"])["run_id"], "r1")

    def test_run_sweep_reports_a_hard_lock_admission_cancellation(self):
        self.store.set_meta("run_sweep_cursor", "2026-11-04T00:00:00Z")
        self.pc.issues = [_issue("i1", status="todo", updated="2026-11-04T00:00:00Z")]
        self.pc.runs_recent = [
            {"id": "r9", "status": "cancelled", "finishedAt": "2026-11-04T01:00:00Z", "issueId": "i1"}
        ]
        self.pc.runs_by_issue["i1"] = [{"id": "r9", "errorCode": "agent_not_invokable"}]

        self.assertEqual(self.p.tick(), 1)
        self.assertEqual(self.store.event_for_issue("i1")["event_type"], "opc.run.admission_cancelled")

    def test_run_sweep_baselines_on_first_run(self):
        self.pc.runs_recent = [
            {"id": "r1", "status": "failed", "finishedAt": "2026-11-04T01:00:00Z", "issueId": "i1"}
        ]
        self.pc.issues = [_issue("i1", status="in_progress", updated="2026-11-04T00:00:00Z")]

        self.assertEqual(self.p.tick(), 0)
        self.assertEqual(self.store.get_meta("run_sweep_cursor"), "2026-11-04T01:00:00Z")

    def test_run_sweep_reports_a_failure_on_a_blocked_ticket(self):
        # Paperclip blocks the ticket because the run failed; that must not
        # suppress the failure event (the first version of the sweep did).
        self.store.set_meta("run_sweep_cursor", "2026-11-04T00:00:00Z")
        self.pc.issues = [
            _issue("i1", status="blocked", updated="2026-11-04T01:30:00Z", blockedTransitionAt="2026-11-04T01:30:00Z")
        ]
        self.pc.runs_recent = [
            {"id": "r1", "status": "failed", "finishedAt": "2026-11-04T01:00:00Z", "issueId": "i1"}
        ]

        self.assertEqual(self.p.tick(), 1)

    def test_run_sweep_skips_done_or_cancelled_issues_and_company_runs(self):
        self.store.set_meta("run_sweep_cursor", "2026-11-04T00:00:00Z")
        self.pc.issues = [
            _issue("i1", status="done", updated="2026-11-04T01:30:00Z", completedAt="2026-11-04T01:30:00Z"),
            _issue("i2", status="cancelled", updated="2026-11-04T01:30:00Z", cancelledAt="2026-11-04T01:30:00Z"),
        ]
        self.pc.runs_recent = [
            {"id": "r1", "status": "failed", "finishedAt": "2026-11-04T01:00:00Z", "issueId": "i1"},
            {"id": "r2", "status": "failed", "finishedAt": "2026-11-04T01:05:00Z", "issueId": "i2"},
            {"id": "r3", "status": "failed", "finishedAt": "2026-11-04T01:10:00Z", "issueId": None},
        ]

        self.assertEqual(self.p.tick(), 0)

    def test_run_sweep_advances_and_survives_a_restart(self):
        self.store.set_meta("run_sweep_cursor", "2026-11-04T00:00:00Z")
        self.pc.issues = [_issue("i1", status="in_progress", updated="2026-11-04T00:00:00Z")]
        self.pc.runs_recent = [
            {"id": "r1", "status": "failed", "finishedAt": "2026-11-04T01:00:00Z", "issueId": "i1"}
        ]
        self.assertEqual(self.p.tick(), 1)
        self.assertEqual(self.store.get_meta("run_sweep_cursor"), "2026-11-04T01:00:00Z")

        # A restart re-reads the overlap window; dedupe must absorb it.
        self.pc.issues = [_issue("i1", status="in_progress", updated="2026-11-04T00:00:00Z")]
        self.assertEqual(self.p.tick(), 0)

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
        # A bridge that bootstrapped yesterday must still recover today's work.
        self.store.set_cursor("2026-11-03T00:00:00Z", bootstrapped_at="2026-11-03T00:00:00Z")
        self.pc.issues = [
            _issue("i7", status="done", updated="2026-11-04T01:00:00Z", completedAt="2026-11-04T01:00:00Z")
        ]

        self.assertEqual(self.p.reconcile(), 1)
        self.assertEqual(self.p.reconcile(), 0)

    def test_reconcile_does_not_replay_pre_cutover_history(self):
        # Baseline is observed-not-delivered. Ten minutes after a first install
        # reconcile runs; it must not re-announce the board.
        self.p.bootstrap()
        self.pc.issues = [
            _issue("i-old", status="done", updated="2026-11-04T01:00:00Z", completedAt="2026-11-04T01:00:00Z")
        ]

        self.assertEqual(self.p.reconcile(), 0)

    def test_backfill_ignores_the_cutover_watermark(self):
        # The explicit history path is allowed to deliver pre-cutover tickets.
        self.p.bootstrap()
        self.pc.issues = [
            _issue("i-old", status="done", updated="2026-11-04T01:00:00Z", completedAt="2026-11-04T01:00:00Z")
        ]

        self.assertEqual(self.p.backfill("2026-11-01T00:00:00Z"), 1)

    def test_backfill_is_explicit_and_idempotent(self):
        self.pc.issues = [
            _issue("i8", status="cancelled", updated="2026-11-04T01:00:00Z", cancelledAt="2026-11-04T01:00:00Z")
        ]

        self.assertEqual(self.p.backfill("2026-11-01T00:00:00Z"), 1)
        self.assertEqual(self.p.backfill("2026-11-01T00:00:00Z"), 0)

    # ── artifacts ────────────────────────────────────────────────────────
    # ── tracks ───────────────────────────────────────────────────────────
    def test_track_comes_from_the_label_before_the_assignee(self):
        self.pc.agents = lambda: [{"id": "a-eng", "name": "Fullstack Engineer", "role": "engineer"}]
        self.pc.issues = [
            _issue(
                "i1",
                status="in_progress",
                updated="2026-11-04T00:00:00Z",
                labelIds=["label-track:lab"],
                assigneeAgentId="a-eng",
            )
        ]
        self.p.bootstrap()
        self.assertEqual(self.p.issue_track(self.pc.issues[0]), "lab")

    def test_backfill_labels_an_unlabeled_legacy_ticket_from_its_assignee(self):
        self.pc.agent_rows = [{"id": "a-eng", "name": "Fullstack Engineer", "role": "engineer"}]
        self.pc.issues = [_issue("i1", status="todo", updated="2026-11-04T00:00:00Z", assigneeAgentId="a-eng")]
        self.p.bootstrap()

        changed = self.p.backfill_labels()

        self.assertEqual(changed, 1)
        issue_id, body = self.pc.patched_issues[0]
        self.assertEqual(issue_id, "i1")
        self.assertIn("label-track:core", body["labelIds"])

    def test_cross_track_assignment_emits_a_violation(self):
        self.pc.agent_rows = [{"id": "a-eng", "name": "Fullstack Engineer", "role": "engineer"}]
        self.pc.issues = [
            _issue(
                "i4", status="todo", updated="2026-11-04T00:00:00Z",
                labelIds=["label-track:lab"], assigneeAgentId="a-eng",
            )
        ]
        self.p.bootstrap()

        self.p.backfill_labels()
        self.p.backfill_labels()

        self.assertEqual(self.store.count_deliveries(), 1)
        row = self.store.event_for_issue("i4")
        self.assertEqual(row["event_type"], "opc.policy.violation")
        self.assertIn("cross_track_assignment", row["payload"])

    def test_conflicting_track_labels_emit_a_violation(self):
        self.pc.agent_rows = [{"id": "a-eng", "name": "Fullstack Engineer", "role": "engineer"}]
        self.pc.issues = [
            _issue(
                "i3", status="todo", updated="2026-11-04T00:00:00Z",
                labelIds=["label-track:core", "label-track:lab"], assigneeAgentId="a-eng",
            )
        ]
        self.p.bootstrap()

        self.p.backfill_labels()
        self.p.backfill_labels()

        self.assertEqual(self.store.count_deliveries(), 1)
        self.assertEqual(self.store.event_for_issue("i3")["event_type"], "opc.policy.violation")

    def test_unknown_track_emits_one_violation(self):
        self.pc.issues = [_issue("i2", status="todo", updated="2026-11-04T00:00:00Z")]
        self.p.bootstrap()

        self.p.backfill_labels()
        self.p.backfill_labels()

        self.assertEqual(self.store.count_deliveries(), 1)
        self.assertEqual(self.store.event_for_issue("i2")["event_type"], "opc.policy.violation")

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
