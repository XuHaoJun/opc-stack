"""Paperclip REST client tests.

The client is the only thing that talks to the work plane, so three properties
carry the system: a non-2xx answer is an error (never an empty list that looks
like "no work"), the bearer token rides on every request and never leaks into
an exception string, and the real envelope shapes are parsed.
"""

import json
import unittest

from opc_bridge import paperclip

from .fakes import FakePaperclip


class PaperclipClientTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakePaperclip()
        self.addCleanup(self.fake.close)
        self.client = paperclip.Paperclip(self.fake.base_url, "test-key", company_id="c1")

    # ── issues ───────────────────────────────────────────────────────────
    def test_list_issues_accepts_a_bare_array(self):
        self.fake.respond_with([{"id": "i1", "identifier": "OPC-1"}])

        rows = self.client.issues_updated_since("2026-01-01T00:00:00Z")

        self.assertEqual(rows[0]["identifier"], "OPC-1")
        self.assertIn("updatedSince=2026-01-01T00%3A00%3A00Z", self.fake.last_request["path"])
        self.assertIn("/api/companies/c1/issues", self.fake.last_request["path"])

    def test_list_issues_accepts_an_object_envelope(self):
        self.fake.respond_with({"issues": [{"id": "i2"}]})

        self.assertEqual(self.client.issues_updated_since("2026-01-01T00:00:00Z"), [{"id": "i2"}])

    def test_401_is_an_error_not_an_empty_list(self):
        self.fake.respond_status(401, "unauthorized")

        with self.assertRaises(paperclip.PaperclipError) as caught:
            self.client.issues_updated_since("2026-01-01T00:00:00Z")

        self.assertEqual(caught.exception.status, 401)
        self.assertNotIn("Bearer", str(caught.exception))
        self.assertNotIn("test-key", str(caught.exception))

    def test_every_request_carries_the_bearer_token(self):
        self.fake.respond_with([])
        self.client.agents()

        self.assertEqual(self.fake.last_headers["Authorization"], "Bearer test-key")

    # ── mutations ────────────────────────────────────────────────────────
    def test_patch_agent_sends_json_and_the_right_verb(self):
        self.fake.respond_with({"id": "a1", "status": "paused"})

        self.client.patch_agent("a1", {"status": "paused"})

        request = self.fake.last_request
        self.assertEqual(request["method"], "PATCH")
        self.assertEqual(request["path"], "/api/agents/a1")
        self.assertEqual(json.loads(request["body"]), {"status": "paused"})

    def test_cancel_run_posts_to_the_run_path(self):
        self.fake.respond_with({"id": "r1", "status": "cancelled"})

        self.client.cancel_run("r1")

        self.assertEqual(self.fake.last_request["method"], "POST")
        self.assertEqual(self.fake.last_request["path"], "/api/heartbeat-runs/r1/cancel")

    # ── reads used later ─────────────────────────────────────────────────
    def test_comments_and_runs_unwrap_their_envelopes(self):
        self.fake.respond_with({"comments": [{"body": "x"}]})
        self.assertEqual(self.client.comments("i1"), [{"body": "x"}])

        self.fake.respond_with({"runs": [{"id": "r1"}]})
        self.assertEqual(self.client.runs_for_issue("i1"), [{"id": "r1"}])

    def test_company_is_resolved_once_and_cached(self):
        self.fake.respond_with([{"id": "c9"}])
        client = paperclip.Paperclip(self.fake.base_url, "k")

        self.assertEqual(client.company(), "c9")
        self.assertEqual(client.company(), "c9")
        self.assertEqual(self.fake.paths().count("/api/companies"), 1)

    def test_issue_and_live_runs_paths(self):
        self.fake.respond_with({"id": "i1"})
        self.client.issue("i1")
        self.assertEqual(self.fake.last_request["path"], "/api/issues/i1")

        self.fake.respond_with({"runs": []})
        self.client.live_runs()
        self.assertEqual(self.fake.last_request["path"], "/api/companies/c1/live-runs")


if __name__ == "__main__":
    unittest.main()
