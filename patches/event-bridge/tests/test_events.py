"""Event contract tests.

The ids are the dedupe key for the whole system, so the properties that matter
are: a re-opened and re-completed issue produces a *new* id (the old one must
not swallow it), the same transition produces the same id across restarts (a
crash must be recoverable by re-sending), and a baseline observation produces
no event at all (cutover must not replay the board).
"""

import unittest

from opc_bridge import events


def _event(**overrides):
    fields = dict(
        schema_version=1,
        event_id="evt_0123456789ab",
        event_type="paperclip.issue.completed",
        source="paperclip",
        company_id="c1",
        project_id="p1",
        issue_id="i1",
        issue_identifier="OPC-7",
        issue_title="Build the thing",
        run_id=None,
        status="done",
        occurred_at="2026-11-04T02:00:00Z",
        observed_at="2026-11-04T02:00:05Z",
        artifact_url="https://example.test/repo",
        origin_channel_id="11111111-1111-1111-1111-111111111111",
        origin_event_id="a" * 64,
        correlation_id="opc-7-done",
        track="lab",
    )
    fields.update(overrides)
    return events.Event(**fields)


class EventIdTest(unittest.TestCase):
    def test_reopened_and_recompleted_issue_gets_a_new_event_id(self):
        first = events.issue_event_id("i1", "done", "2026-11-04T02:00:00Z")
        second = events.issue_event_id("i1", "done", "2026-11-04T03:00:00Z")

        self.assertNotEqual(first, second)
        self.assertTrue(first.startswith("evt_"))
        self.assertEqual(len(first), 16)

    def test_same_transition_is_stable_across_restarts(self):
        self.assertEqual(
            events.issue_event_id("i1", "done", "T"),
            events.issue_event_id("i1", "done", "T"),
        )

    def test_status_is_part_of_the_key(self):
        self.assertNotEqual(
            events.issue_event_id("i1", "done", "T"),
            events.issue_event_id("i1", "cancelled", "T"),
        )

    def test_run_and_health_ids_are_deterministic_and_distinct(self):
        self.assertEqual(events.run_event_id("r1", "failed"), events.run_event_id("r1", "failed"))
        self.assertNotEqual(events.run_event_id("r1", "failed"), events.run_event_id("r1", "timed_out"))
        self.assertNotEqual(events.health_event_id("r1", "stalled", 1), events.health_event_id("r1", "stalled", 2))
        self.assertEqual(events.health_event_id("r1", "stalled", 1), events.health_event_id("r1", "stalled", 1))


class ClassifyTest(unittest.TestCase):
    def test_classify_only_emits_on_change(self):
        self.assertEqual(
            events.classify_issue({"status": "in_progress"}, {"status": "done", "completedAt": "T"}),
            "paperclip.issue.completed",
        )
        self.assertIsNone(
            events.classify_issue({"status": "done"}, {"status": "done", "completedAt": "T"})
        )
        # Baseline: first observation of an already-terminal issue is history,
        # not a transition, so cutover stays quiet.
        self.assertIsNone(events.classify_issue(None, {"status": "done", "completedAt": "T"}))

    def test_blocked_reassert_is_a_new_event_when_transition_ts_changes(self):
        previous = {"status": "blocked", "blockedTransitionAt": "T1"}
        self.assertEqual(
            events.classify_issue(previous, {"status": "blocked", "blockedTransitionAt": "T2"}),
            "paperclip.issue.blocked",
        )
        self.assertIsNone(
            events.classify_issue(previous, {"status": "blocked", "blockedTransitionAt": "T1"})
        )

    def test_cancelled_and_unknown_statuses(self):
        self.assertEqual(
            events.classify_issue({"status": "todo"}, {"status": "cancelled", "cancelledAt": "T"}),
            "paperclip.issue.cancelled",
        )
        self.assertIsNone(events.classify_issue({"status": "todo"}, {"status": "in_review"}))

    def test_terminal_ts_prefers_the_status_specific_column(self):
        issue = {
            "status": "done",
            "completedAt": "TC",
            "cancelledAt": "TX",
            "updatedAt": "TU",
        }
        self.assertEqual(events.terminal_ts(issue), "TC")
        self.assertEqual(events.terminal_ts({"status": "cancelled", "cancelledAt": "TX"}), "TX")
        self.assertEqual(events.terminal_ts({"status": "blocked", "updatedAt": "TU"}), "TU")
        self.assertIsNone(events.terminal_ts({"status": "todo", "updatedAt": "TU"}))


class RenderTest(unittest.TestCase):
    def test_message_carries_machine_line_and_destination_fields(self):
        evt = _event()
        msg = events.render_message(evt, {"title": "t", "identifier": "OPC-7"}, "https://board.example")

        self.assertTrue(msg.rstrip().endswith(f"OPC_EVENT: {evt.event_id}"))
        self.assertIn("https://board.example/issues/OPC-7", msg)
        self.assertIn("OPC-7", msg)

    def test_message_without_public_url_still_names_the_ticket(self):
        evt = _event()
        msg = events.render_message(evt, {"title": "t", "identifier": "OPC-7"}, "")
        self.assertIn("OPC-7", msg)
        self.assertNotIn("/issues/", msg)

    def test_message_can_carry_the_title_without_a_live_issue_read(self):
        evt = _event()
        msg = events.render_message(evt, {}, "")
        self.assertIn("Build the thing", msg)

    def test_tags_are_stable_and_scoped(self):
        evt = _event()
        tags = events.event_tags(evt)
        self.assertEqual(
            tags,
            {
                "opc-event": evt.event_id,
                "opc-event-type": "paperclip.issue.completed",
                "opc-issue": "OPC-7",
                "opc-track": "lab",
            },
        )

    def test_event_roundtrips_through_dict(self):
        evt = _event()
        self.assertEqual(events.Event.from_dict(evt.to_dict()), evt)
        self.assertEqual(evt.to_dict()["schema_version"], 1)


if __name__ == "__main__":
    unittest.main()
