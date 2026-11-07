"""Force stop tests: one run, verified, never a workspace."""

import tempfile
import unittest
from pathlib import Path

from opc_bridge import config, control, store


class FakePaperclip:
    def __init__(self):
        self.runs = {
            "run-1": {"id": "run-1", "status": "running", "issueId": "i1"},
            "run-2": {"id": "run-2", "status": "running", "issueId": "i2"},
            "run-done": {"id": "run-done", "status": "succeeded", "issueId": "i3"},
        }
        self.cancelled = []
        self.comments = []

    def run(self, run_id):
        return self.runs.get(run_id, {})

    def cancel_run(self, run_id):
        self.cancelled.append(run_id)
        self.runs[run_id]["status"] = "cancelled"
        return self.runs[run_id]

    def _request(self, method, path, body=None):
        self.comments.append(body)
        return {}


class ForceStopTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.store = store.Store(Path(tmp.name) / "f.db")
        self.addCleanup(self.store.close)
        self.pc = FakePaperclip()

    def stop(self, run_id):
        return control.force_stop(self.pc, run_id, "operator:test", "e" * 64, self.store, "2026-11-04T02:00:00Z")

    def test_cancels_only_the_named_run(self):
        result = self.stop("run-1")
        self.assertEqual(self.pc.cancelled, ["run-1"])
        self.assertEqual(self.pc.runs["run-2"]["status"], "running")
        self.assertEqual(result["status"], "cancelled")

    def test_terminal_run_is_not_cancellable(self):
        with self.assertRaises(control.ForceStopError) as caught:
            self.stop("run-done")
        self.assertEqual(caught.exception.reason, "not_cancellable")
        self.assertEqual(self.pc.cancelled, [])

    def test_unknown_run_is_not_found(self):
        with self.assertRaises(control.ForceStopError) as caught:
            self.stop("nope")
        self.assertEqual(caught.exception.reason, "not_found")

    def test_audit_and_issue_comment_are_written(self):
        self.stop("run-1")
        self.assertEqual(self.store.audit_rows()[-1]["action"], "force_stop")
        self.assertTrue(self.pc.comments)
        self.assertIn("OPC_CONTROL: force-stop run=run-1", self.pc.comments[-1]["body"])


if __name__ == "__main__":
    unittest.main()
