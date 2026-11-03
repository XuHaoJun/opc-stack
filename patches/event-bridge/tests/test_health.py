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

    def live_runs(self):
        return self.live

    def run(self, run_id):
        return self.runs[run_id]

    def agents(self):
        return self.agents_rows


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

    def test_running_while_issue_terminal_is_lost(self):
        run = {"id": "r", "status": "running", "issueStatus": "done", "startedAt": T0}
        self.assertEqual(health.classify(run, T0, "idle", T0 + 10, 900, 1800), "lost")

    def test_running_under_a_paused_agent_is_lost(self):
        run = {"id": "r", "status": "running", "startedAt": T0}
        self.assertEqual(health.classify(run, T0, "paused", T0 + 10, 900, 1800), "lost")

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

    def test_unknown_is_not_notified(self):
        self.pc.runs["r1"] = {"id": "r1", "status": "running", "agentId": "a1", "startedAt": T0}
        self.pc.live = [{"id": "r1", "status": "running"}]
        self.pc.agents_rows = [{"id": "a1", "status": "idle"}]
        self.assertEqual(self.monitor.tick(T0 + 3600), 0)

    def test_no_cancel_is_ever_requested(self):
        self.stalled()
        self.monitor.tick(T0 + 1801)
        self.assertFalse(hasattr(self.pc, "cancelled"))
        self.assertTrue(callable(getattr(self.pc, "run", None)))


if __name__ == "__main__":
    unittest.main()
