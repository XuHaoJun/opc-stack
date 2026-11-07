"""Policy precedence tests.

These are the rules Hermes cites when it refuses work, so a wrong answer here
silently widens autonomy. Each test names the winner it expects and why.
"""

import json
import tempfile
import unittest
import uuid
from pathlib import Path

from opc_bridge import config, policy, store

NOW = "2026-11-04T00:00:00Z"


class PolicyStore:
    """Thin fixture over the real Store so the sqlite paths are covered too."""

    def __init__(self, path: Path) -> None:
        self.store = store.Store(path)

    def add_override(self, scope, scope_id, key, value, actor="operator:x", created_at="2026-11-01T00:00:00Z"):
        self.store.insert_policy(
            {
                "id": str(uuid.uuid4()),
                "scope_kind": scope,
                "scope_id": scope_id,
                "key": key,
                "value_json": json.dumps(value),
                "priority": policy.PRIORITY["operator"],
                "created_by": actor,
                "reason": "test",
                "created_at": created_at,
            }
        )

    def add_mandate(
        self,
        scope="track",
        scope_id="lab",
        track="lab",
        followups_allowed=False,
        style="exploration",
        expires_at=None,
        allowed=None,
        restricted=None,
        created_at="2026-11-01T00:00:00Z",
    ):
        mandate_id = str(uuid.uuid4())
        self.store.insert_mandate(
            {
                "id": mandate_id,
                "scope_kind": scope,
                "scope_id": scope_id,
                "style": style,
                "track": track,
                "allowed_json": json.dumps(allowed or []),
                "restricted_json": json.dumps(restricted or []),
                "followups_allowed": followups_allowed,
                "review_policy": "hermes_report",
                "created_by": "operator:x",
                "created_at": created_at,
                "expires_at": expires_at,
            }
        )
        return mandate_id


class PolicyTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.store = PolicyStore(Path(tmp.name) / "p.db")
        self.addCleanup(self.store.store.close)

    def effective(self, project="p1", track="lab"):
        return policy.effective(self.store.store, "c1", project, track, NOW)

    def test_defaults_are_conservative(self):
        values = self.effective()["values"]
        self.assertFalse(values["followups.allowed"])
        self.assertEqual(values["style"], "blueprint")
        self.assertFalse(values["track_locked"])

    def test_operator_override_beats_mandate_and_default(self):
        self.store.add_override("track", "lab", "followups.allowed", False)
        self.store.add_mandate(followups_allowed=True)

        result = self.effective()

        self.assertFalse(result["values"]["followups.allowed"])
        self.assertEqual(result["provenance"]["followups.allowed"]["priority"], 20)

    def test_mandate_beats_default(self):
        self.store.add_mandate(followups_allowed=True)
        self.assertTrue(self.effective()["values"]["followups.allowed"])

    def test_expired_mandate_resolves_to_nothing(self):
        self.store.add_mandate(followups_allowed=True, expires_at="2000-01-01T00:00:00Z")
        self.assertFalse(self.effective()["values"]["followups.allowed"])

    def test_project_beats_track_and_newest_wins_inside_a_scope(self):
        self.store.add_mandate(scope="track", scope_id="lab", followups_allowed=True)
        self.store.add_mandate(
            scope="project", scope_id="p1", followups_allowed=False, created_at="2026-11-02T00:00:00Z"
        )
        result = self.effective()
        self.assertFalse(result["values"]["followups.allowed"])
        self.assertEqual(result["provenance"]["followups.allowed"]["scope"], "project")

    def test_two_equal_grants_resolve_to_the_more_restrictive(self):
        self.store.add_mandate(followups_allowed=True)
        self.store.add_mandate(followups_allowed=False)
        self.assertFalse(self.effective()["values"]["followups.allowed"])

    def test_hard_rule_cannot_be_enabled_by_a_mandate(self):
        self.store.add_mandate(allowed=["production_deploy"])
        allowed, reason = policy.check(
            self.store.store, "c1", "p1", "lab", "production_deploy", NOW
        )
        self.assertFalse(allowed)
        self.assertEqual(reason, "hard rule")

    def test_action_outside_the_mandate_is_refused(self):
        self.store.add_mandate(allowed=["create_followup"])
        self.assertTrue(policy.check(self.store.store, "c1", "p1", "lab", "create_followup", NOW)[0])
        allowed, reason = policy.check(self.store.store, "c1", "p1", "lab", "force_stop", NOW)
        self.assertFalse(allowed)
        self.assertEqual(reason, "not allowed by any active mandate")

    def test_track_lock_blocks_any_action(self):
        self.store.add_override("track", "lab", "track_locked", True)
        allowed, reason = policy.check(self.store.store, "c1", "p1", "lab", "create_followup", NOW)
        self.assertFalse(allowed)
        self.assertEqual(reason, "track is locked by the operator")

    def test_revoked_mandate_is_ignored(self):
        mandate_id = self.store.add_mandate(followups_allowed=True)
        self.store.store.revoke_mandate(mandate_id, "2026-11-03T00:00:00Z", "operator:x")
        self.assertFalse(self.effective()["values"]["followups.allowed"])

    def test_a_company_row_written_as_default_applies_to_the_real_company(self):
        import uuid

        self.store.store.insert_policy(
            {
                "id": str(uuid.uuid4()),
                "scope_kind": "company",
                "scope_id": "default",
                "key": "allocation.lab",
                "value_json": "0",
                "priority": 20,
                "created_by": "ops:test",
                "reason": "test",
                "created_at": "2026-11-01T00:00:00Z",
            }
        )
        eff = policy.effective(self.store.store, "real-company-uuid", None, "lab", NOW)
        self.assertEqual(eff["values"]["allocation.lab"], 0)

    def test_provenance_exists_for_every_key(self):
        result = self.effective()
        self.assertEqual(set(result["values"]), set(result["provenance"]))


if __name__ == "__main__":
    unittest.main()
