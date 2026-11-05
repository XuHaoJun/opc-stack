"""Allocation and pause tests.

The hard lock is the operator's "Lab 0%" switch, so the tests pin: only the
locked track is touched, the lock is re-asserted after a restart, and a resume
refuses when somebody else changed the holds in the meantime.
"""

import tempfile
import unittest
from pathlib import Path

from opc_bridge import config, control, store

NOW = "2026-11-04T02:00:00Z"


class FakeAgentApi:
    def __init__(self):
        self.rows = [
            {"id": "a-core", "name": "Fullstack Engineer", "role": "engineer", "status": "idle", "lifecycleState": "ready", "lifecycleHolds": [],
             "runtimeConfig": {"heartbeat": {"maxConcurrentRuns": 4, "enabled": False}, "debug": {"providerTrace": True}}},
            {"id": "a-proto", "name": "Prototyper", "role": "general", "status": "idle", "lifecycleState": "ready", "lifecycleHolds": []},
            {"id": "a-sci", "name": "Scientist", "role": "general", "status": "idle", "lifecycleState": "ready", "lifecycleHolds": []},
        ]
        self.patches = []

    def agents(self):
        return list(self.rows)

    def agent(self, agent_id):
        return next(a for a in self.rows if a["id"] == agent_id)

    def patch_agent(self, agent_id, body):
        self.patches.append((agent_id, body))
        row = self.agent(agent_id)
        if "status" in body:
            row["status"] = "paused" if body["status"] == "paused" else "idle"
            row["lifecycleState"] = "paused" if body["status"] == "paused" else "ready"
        if "runtimeConfig" in body:
            row["maxConcurrentRuns"] = body["runtimeConfig"]["heartbeat"]["maxConcurrentRuns"]
        return row


class AllocationTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.cfg = config.load({"OPC_DB_PATH": str(Path(tmp.name) / "a.db")})
        self.store = store.Store(self.cfg.db_path)
        self.addCleanup(self.store.close)
        self.pc = FakeAgentApi()

    def apply(self, core, lab, adaptive=False):
        return control.apply_allocation(
            self.cfg, self.store, self.pc, core, lab, "ops:test", None, NOW, adaptive=adaptive
        )

    def test_slot_plan(self):
        self.assertEqual(control.slot_plan(70, 30, 6, 2), {"core": 4, "lab_per_agent": 1})
        self.assertEqual(control.slot_plan(100, 0, 6, 2)["lab_per_agent"], 0)

    def test_zero_share_pauses_only_that_track(self):
        result = self.apply(100, 0)
        self.assertTrue(result["applied"])
        self.assertEqual(self.pc.agent("a-core")["status"], "idle")
        self.assertEqual(self.pc.agent("a-proto")["status"], "paused")
        self.assertEqual(self.pc.agent("a-sci")["status"], "paused")
        self.assertEqual(self.store.track_state("lab")["state"], "paused")

    def test_resume_restores_only_ledgered_agents(self):
        self.apply(100, 0)
        self.apply(70, 30)
        self.assertEqual(self.pc.agent("a-proto")["status"], "idle")
        self.assertTrue(self.store.ledger_get("a-proto")["released_at"])

    def test_resume_refuses_when_a_human_changed_the_holds(self):
        self.apply(100, 0)
        self.pc.agent("a-sci")["lifecycleHolds"] = ["manual", "user-hold"]
        result = self.apply(70, 30)
        self.assertIn("refused:a-sci", result["changed"])
        self.assertEqual(self.pc.agent("a-sci")["status"], "paused")

    def test_reconcile_reasserts_an_open_lock(self):
        self.apply(100, 0)
        self.pc.agent("a-proto")["status"] = "idle"
        self.pc.agent("a-proto")["lifecycleState"] = "ready"
        result = control.reconcile_lock(self.cfg, self.store, self.pc, NOW)
        self.assertIn("a-proto", result["paused"])
        self.assertEqual(self.pc.agent("a-proto")["status"], "paused")

    def test_an_unlocked_track_is_not_re_paused_after_a_restart(self):
        # Reviewer's finding 2: a stale ledger row re-paused an agent after the
        # operator unlocked the track while the agent was not paused.
        import json
        import uuid

        self.apply(100, 0)
        self.store.insert_policy(
            {
                "id": str(uuid.uuid4()),
                "scope_kind": "company",
                "scope_id": "default",
                "key": "allocation.lab",
                "value_json": json.dumps(30),
                "priority": 20,
                "created_by": "operator:test",
                "reason": "unlock",
                "created_at": "2026-11-04T03:00:00Z",  # newer than the lock row
            }
        )
        # A human (or a partial unlock) resumed the agent; the ledger row is open.
        self.pc.agent("a-proto")["status"] = "idle"
        self.pc.agent("a-proto")["lifecycleState"] = "ready"

        control.reconcile_lock(self.cfg, self.store, self.pc, NOW)

        self.assertEqual(self.pc.agent("a-proto")["status"], "idle")
        self.assertIsNotNone(self.store.ledger_get("a-proto")["released_at"])

    def test_relocking_reopens_the_ledger_for_an_agent_we_paused_before(self):
        self.apply(100, 0)
        self.apply(70, 30)          # resume + release
        self.apply(100, 0)          # agents are already paused; the row must reopen
        self.assertIsNone(self.store.ledger_get("a-proto")["released_at"])
        self.apply(70, 30)
        self.assertEqual(self.pc.agent("a-proto")["status"], "idle")

    def test_adaptive_does_not_override_an_operator_allocation(self):
        self.apply(100, 0)
        result = self.apply(90, 10, adaptive=True)
        self.assertFalse(result["applied"])
        self.assertEqual(self.pc.agent("a-proto")["status"], "paused")

    def test_slot_write_merges_runtime_config_instead_of_replacing_it(self):
        self.apply(70, 30)
        body = next(p for agent_id, p in self.pc.patches if agent_id == "a-core" and "runtimeConfig" in p)
        config = body["runtimeConfig"]
        self.assertEqual(config["heartbeat"]["maxConcurrentRuns"], 4)
        self.assertFalse(config["heartbeat"]["enabled"])       # preserved
        self.assertTrue(config["debug"]["providerTrace"])      # preserved

    def test_allocation_must_sum_to_one_hundred(self):
        with self.assertRaises(control.PolicyError):
            self.apply(70, 20)

    def test_unknown_selector_is_an_error(self):
        cfg = config.load({"OPC_DB_PATH": str(self.store.path), "OPC_TRACK_LAB_AGENTS": "name:Nobody"})
        with self.assertRaises(control.PolicyError):
            control.apply_allocation(cfg, self.store, self.pc, 70, 30, "ops:test", None, NOW)


if __name__ == "__main__":
    unittest.main()
