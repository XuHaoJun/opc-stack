"""Health classification tests.

The load-bearing one is the negative: a run we cannot see into is `unknown`,
and nothing here may cancel a run. The clock is injected so the 30-minute
thresholds are exercised in milliseconds.
"""

import inspect
import tempfile
import unittest
from pathlib import Path

from opc_bridge import config, health, store

T0 = 1_800_000_000.0


class FakePaperclip:
    def __init__(self):
        self.live = []
        self.runs = {}
        self.agents_rows = []
        self.issues = {"i1": {"status": "in_progress"}}

    def live_runs(self):
        return self.live

    def run(self, run_id):
        return self.runs[run_id]

    def agents(self):
        return self.agents_rows

    def issue(self, issue_id):
        return self.issues.get(issue_id, {"status": "in_progress"})


class ClassifyTest(unittest.TestCase):
    def test_gateway_run_without_pid_or_progress_is_unknown(self):
        self.assertEqual(
            health.classify({"id": "r", "status": "running"}, None, "idle", T0, 900, 1800),
            "unknown",
        )

    def test_silence_past_stall_with_abnormal_signal_is_stalled(self):
        run = {"id": "r", "status": "running", "outputSilence": {"level": "critical", "lastOutputAt": T0}}
        self.assertEqual(health.classify(run, T0, "idle", T0 + 1801, 900, 1800), "suspected_stalled")

    def test_silence_past_stall_without_signal_is_unknown_not_stalled(self):
        run = {"id": "r", "status": "running", "startedAt": T0}
        self.assertEqual(health.classify(run, T0, "idle", T0 + 1801, 900, 1800), "unknown")

    def test_a_run_finishing_just_after_its_ticket_closes_is_not_lost(self):
        # Real incident: the agent sets `done`, then finishes the run a few
        # seconds later. That overlap is Paperclip's normal flow, not an
        # inconsistency.
        run = {"id": "r", "status": "running", "issueId": "i1", "startedAt": T0}
        self.assertNotEqual(
            health.classify(
                run, T0 + 7, "idle", T0 + 10, 900, 1800,
                issue_status="done", issue_terminal_at=T0 + 7,
            ),
            "lost",
        )

    def test_a_run_still_running_long_after_its_ticket_closed_is_lost(self):
        run = {"id": "r", "status": "running", "issueId": "i1", "startedAt": T0}
        self.assertEqual(
            health.classify(
                run, T0, "idle", T0 + 2000, 900, 1800,
                issue_status="done", issue_terminal_at=T0, terminal_grace=120,
            ),
            "lost",
        )

    def test_terminal_issue_without_a_timestamp_is_not_called_lost(self):
        run = {"id": "r", "status": "running", "issueId": "i1", "startedAt": T0}
        self.assertNotEqual(
            health.classify(run, None, "idle", T0 + 2000, 900, 1800, issue_status="done"),
            "lost",
        )

    def test_a_finishing_run_under_our_own_lock_is_not_lost(self):
        # The hard lock pauses agents while in-flight work finishes; recent
        # output means this is expected, not an inconsistency.
        run = {"id": "r", "status": "running", "startedAt": T0}
        self.assertNotEqual(health.classify(run, T0 + 7, "paused", T0 + 10, 900, 1800), "lost")

    def test_a_run_silent_under_a_paused_agent_is_lost(self):
        run = {"id": "r", "status": "running", "startedAt": T0}
        self.assertEqual(health.classify(run, T0, "paused", T0 + 1000, 900, 1800), "lost")

    def test_recent_progress_is_healthy(self):
        run = {"id": "r", "status": "running", "startedAt": T0}
        self.assertEqual(health.classify(run, T0 + 60, "idle", T0 + 120, 900, 1800), "healthy")

    def test_slow_between_the_two_thresholds(self):
        run = {"id": "r", "status": "running", "startedAt": T0}
        self.assertEqual(health.classify(run, T0, "idle", T0 + 1000, 900, 1800), "slow")

    def test_module_never_calls_cancel(self):
        self.assertNotIn("cancel_run", inspect.getsource(health))


class MonitorTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.cfg = config.load({"OPC_DB_PATH": str(Path(tmp.name) / "h.db")})
        self.store = store.Store(self.cfg.db_path)
        self.addCleanup(self.store.close)
        self.pc = FakePaperclip()
        self.monitor = health.HealthMonitor(self.cfg, self.store, self.pc, clock=lambda: T0, log=lambda *_: None)

    def stalled(self):
        self.pc.runs["r1"] = {
            "id": "r1", "status": "running", "startedAt": T0, "agentId": "a1",
            "outputSilence": {"level": "critical", "lastOutputAt": T0},
        }
        self.pc.live = [{"id": "r1", "status": "running"}]
        self.pc.agents_rows = [{"id": "a1", "status": "idle"}]

    def test_first_notification_then_reminder_then_recovery(self):
        self.stalled()
        self.assertEqual(self.monitor.tick(T0 + 1801), 1)          # stalled
        self.assertEqual(self.monitor.tick(T0 + 1801 + 60), 0)     # inside reminder window
        self.assertEqual(self.monitor.tick(T0 + 1801 + 1800), 1)   # reminder

        self.pc.runs["r1"]["outputSilence"]["lastOutputAt"] = T0 + 4000
        self.assertEqual(self.monitor.tick(T0 + 4001), 1)          # recovered

    def test_monitor_reads_the_issue_status_from_the_api(self):
        self.stalled()
        self.pc.runs["r1"]["issueId"] = "i1"
        # Silent for well past the thresholds, ticket long closed.
        self.pc.runs["r1"]["outputSilence"]["lastOutputAt"] = T0 - 3000
        self.pc.issues["i1"] = {"status": "done", "identifier": "OPC-9", "completedAt": T0 - 1000}
        self.assertEqual(self.monitor.tick(T0 + 10), 1)
        row = self.store.recent_events(1)[0]
        self.assertEqual(row["event_type"], "opc.run.lost")
        self.assertEqual(row["issue_identifier"], "OPC-9")

    def test_the_reported_false_lost_is_gone(self):
        # The incident, replayed: ticket closed 3s before the run finished.
        self.pc.runs["r1"] = {
            "id": "r1", "status": "running", "startedAt": T0, "agentId": "a1",
            "issueId": "i1", "outputSilence": {"level": "ok", "lastOutputAt": T0 + 7},
        }
        self.pc.live = [{"id": "r1", "status": "running"}]
        self.pc.agents_rows = [{"id": "a1", "status": "idle"}]
        self.pc.issues["i1"] = {"status": "done", "identifier": "OPC-191", "completedAt": T0 + 7}
        self.assertEqual(self.monitor.tick(T0 + 10), 0)

    def test_unknown_is_not_notified(self):
        self.pc.runs["r1"] = {"id": "r1", "status": "running", "agentId": "a1", "startedAt": T0}
        self.pc.live = [{"id": "r1", "status": "running"}]
        self.pc.agents_rows = [{"id": "a1", "status": "idle"}]
        self.assertEqual(self.monitor.tick(T0 + 3600), 0)

    def test_a_finished_run_leaves_the_abnormal_state(self):
        self.stalled()
        self.assertEqual(self.monitor.tick(T0 + 1801), 1)   # lost/stalled alert
        self.assertEqual(self.store.run_health("r1")["state"], "suspected_stalled")

        self.pc.runs["r1"]["status"] = "succeeded"
        self.pc.live = []
        emitted = self.monitor.tick(T0 + 1900)

        self.assertEqual(emitted, 0)                        # cleared silently
        self.assertEqual(self.store.run_health("r1")["state"], "healthy")
        self.assertEqual(self.store.audit_rows()[-1]["action"], "run_health_cleared")

    def test_no_cancel_is_ever_requested(self):
        self.stalled()
        self.monitor.tick(T0 + 1801)
        self.assertFalse(hasattr(self.pc, "cancelled"))
        self.assertTrue(callable(getattr(self.pc, "run", None)))


if __name__ == "__main__":
    unittest.main()
