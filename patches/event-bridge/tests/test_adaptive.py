"""Adaptive allocation tests: measure, hold, nudge, never override the operator.

The clock is injected so a 30-minute hold is exercised in microseconds.
"""

import json
import tempfile
import unittest
from pathlib import Path

from opc_bridge import adaptive, config, store

T0 = config.parse_iso("2026-11-05T02:00:00Z")


def run(agent, started, finished, status="succeeded"):
    return {"agentId": agent, "startedAt": config.iso(started), "finishedAt": config.iso(finished), "status": status}


class MeasureTest(unittest.TestCase):
    def measure(self, runs, now=T0):
        return adaptive.measure(runs, {"a-core": "core", "a-lab": "lab"}, now, 3600, 2, 60)

    def test_splits_overlapping_run_time_by_track(self):
        result = self.measure([
            run("a-core", T0 - 600, T0 - 300),   # 300s core
            run("a-lab", T0 - 600, T0 - 400),    # 200s lab
        ])
        self.assertTrue(result.sufficient)
        self.assertAlmostEqual(result.core_share, 60.0, places=1)
        self.assertEqual(result.runs, 2)

    def test_clips_runs_to_the_window(self):
        result = self.measure([
            run("a-core", T0 - 7200, T0 - 1800),  # only the last 1800s are inside
            run("a-lab", T0 - 1000, T0 - 900),
        ])
        self.assertAlmostEqual(result.core_share, 1800 / 1900 * 100, places=1)

    def test_ignores_unknown_agents_and_missing_timestamps(self):
        result = self.measure([
            run("someone-else", T0 - 600, T0 - 300),
            {"agentId": "a-core", "startedAt": None, "finishedAt": None},
            run("a-core", T0 - 600, T0 - 300),
            run("a-lab", T0 - 600, T0 - 300),
        ])
        self.assertEqual(result.runs, 2)

    def test_insufficient_runs_or_time_is_not_a_measurement(self):
        self.assertFalse(self.measure([run("a-core", T0 - 600, T0 - 300)]).sufficient)
        self.assertFalse(self.measure([
            run("a-core", T0 - 40, T0 - 30),
            run("a-lab", T0 - 40, T0 - 30),
        ]).sufficient)


class DecideTest(unittest.TestCase):
    def test_within_tolerance_moves_nothing(self):
        self.assertIsNone(adaptive.decide(70, 80.0, 15, 17))

    def test_drift_moves_one_step_toward_the_measured_side(self):
        self.assertEqual(adaptive.decide(70, 95.0, 15, 17), (53, 47))
        self.assertEqual(adaptive.decide(53, 20.0, 15, 17), (70, 30))

    def test_a_step_to_zero_is_refused(self):
        self.assertIsNone(adaptive.decide(10, 95.0, 15, 17))


class ControllerTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.cfg = config.load({
            "OPC_DB_PATH": str(Path(tmp.name) / "a.db"),
            "OPC_SLOT_BUDGET": "6",
            "OPC_ADAPTIVE_MIN_RUNS": "2",
            "OPC_ADAPTIVE_MIN_SECONDS": "60",
            "OPC_ADAPTIVE_HOLD_SECONDS": "1800",
            "PAPERCLIP_COMPANY_ID": "c1",
        })
        self.store = store.Store(self.cfg.db_path)
        self.addCleanup(self.store.close)
        self.pc = FakePaperclip()
        self.ctl = adaptive.AdaptiveController(self.cfg, self.store, self.pc, clock=lambda: T0, log=lambda *_: None)

    def test_operator_override_makes_adaptive_inert(self):
        import uuid

        self.store.insert_policy({
            "id": str(uuid.uuid4()), "scope_kind": "company", "scope_id": "c1",
            "key": "allocation.core", "value_json": "70", "priority": 20,
            "created_by": "operator:test", "reason": "manual", "created_at": "2026-11-04T00:00:00Z",
        })
        self.assertEqual(self.ctl.tick(T0), 0)
        self.assertIn("operator", json.dumps(self.ctl.state()))

    def test_state_does_not_inherit_a_previous_skip(self):
        self.store.set_meta("adaptive_state", '{"skipped": "operator override", "at": "old"}')
        self.pc.runs = [run("a-core", T0 - 600, T0 - 300), run("a-lab", T0 - 600, T0 - 590)]
        self.ctl.tick(T0)
        self.assertNotIn("skipped", self.ctl.state())
        self.assertEqual(self.ctl.state()["decision"], "drift detected")

    def test_insufficient_samples_do_nothing(self):
        self.pc.runs = []
        self.assertEqual(self.ctl.tick(T0), 0)
        self.assertEqual(self.ctl.state()["decision"], "wait")
        self.assertEqual(self.store.list_policy_count(), 0)

    def test_drift_must_hold_before_a_single_step(self):
        self.pc.runs = [run("a-core", T0 - 600, T0 - 300), run("a-lab", T0 - 600, T0 - 590)]
        self.assertEqual(self.ctl.tick(T0), 0)                  # drift detected, no move
        self.assertEqual(self.ctl.state()["decision"], "drift detected")
        self.assertEqual(self.ctl.tick(T0 + 1799), 0)           # still holding
        self.assertEqual(self.ctl.tick(T0 + 1801), 1)           # one step
        values = self.store.effective_allocation("c1", "2026-11-05T03:00:00Z")
        self.assertEqual(values, {"core": 53, "lab": 47})
        self.assertIn("adjusted", self.ctl.state()["decision"])

    def test_direction_change_resets_the_hold(self):
        self.pc.runs = [run("a-core", T0 - 600, T0 - 300), run("a-lab", T0 - 600, T0 - 590)]
        self.ctl.tick(T0)
        self.pc.runs = [run("a-lab", T0 - 600, T0 - 300), run("a-core", T0 - 600, T0 - 590)]
        self.ctl.tick(T0 + 1000)
        self.assertEqual(self.ctl.tick(T0 + 1801), 0)

    def test_adaptive_never_creates_a_zero_share(self):
        import uuid

        self.store.insert_policy({
            "id": str(uuid.uuid4()), "scope_kind": "company", "scope_id": "c1",
            "key": "allocation.core", "value_json": "10", "priority": 40,
            "created_by": "bridge:adaptive", "reason": "seed", "created_at": "2026-11-04T00:00:00Z",
        })
        self.pc.runs = [run("a-core", T0 - 600, T0 - 300), run("a-lab", T0 - 600, T0 - 590)]
        self.ctl.tick(T0)
        self.assertEqual(self.ctl.tick(T0 + 1801), 0)
        self.assertNotIn("0", [str(v) for v in self.store.effective_allocation("c1", "2026-11-05T03:00:00Z").values()])


class FakePaperclip:
    def __init__(self):
        self.rows = [
            {"id": "a-core", "name": "Fullstack Engineer", "role": "engineer", "status": "idle",
             "lifecycleState": "ready", "lifecycleHolds": [], "runtimeConfig": {}},
            {"id": "a-lab", "name": "Prototyper", "status": "idle",
             "lifecycleState": "ready", "lifecycleHolds": [], "runtimeConfig": {}},
            {"id": "a-sci", "name": "Scientist", "status": "idle",
             "lifecycleState": "ready", "lifecycleHolds": [], "runtimeConfig": {}},
        ]
        self.runs: list[dict] = []

    def agents(self):
        return list(self.rows)

    def agent(self, agent_id):
        return next(r for r in self.rows if r["id"] == agent_id)

    def heartbeat_runs(self, limit=100):
        return self.runs[:limit]

    def patch_agent(self, agent_id, body):
        row = self.agent(agent_id)
        if "status" in body:
            row["status"] = "paused" if body["status"] == "paused" else "idle"
            row["lifecycleState"] = "paused" if body["status"] == "paused" else "ready"
        if "runtimeConfig" in body:
            row["runtimeConfig"] = body["runtimeConfig"]
        return row


if __name__ == "__main__":
    unittest.main()
