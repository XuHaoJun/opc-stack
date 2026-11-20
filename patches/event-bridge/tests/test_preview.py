"""Preview stop sweep: only the `preview` service, only when its ticket is over.

The dangerous failure is a stop that takes a sibling service down with it
(`{}` means "all services" upstream) or one that Paperclip's startup recovery
undoes (serviceStates left at "running").
"""

import unittest

from opc_bridge import paperclip, preview


def _ws(wid, issue, services, states=None, config_services=None):
    row = {
        "id": wid,
        "sourceIssueId": issue,
        "runtimeServices": [
            {"id": f"{wid}-{name}", "serviceName": name, "status": status} for name, status in services
        ],
        "config": {
            "workspaceRuntime": {"services": [{"name": n} for n in (config_services or [n for n, _ in services])]},
            "serviceStates": dict(states or {}),
        },
    }
    return row


class StubPc:
    def __init__(self, workspaces, fail_stop=()):
        self.workspaces = workspaces
        self.fail_stop = set(fail_stop)
        self.stops = []
        self.patches = []

    def execution_workspaces(self, issue_id=None):
        return [w for w in self.workspaces if issue_id in (None, w["sourceIssueId"])]

    def stop_runtime_service(self, workspace_id, selector):
        if workspace_id in self.fail_stop:
            raise paperclip.PaperclipError(500, "boom")
        self.stops.append((workspace_id, dict(selector)))
        return {}

    def patch_execution_workspace(self, workspace_id, body):
        self.patches.append((workspace_id, body))
        return {}


def _fixture():
    return [
        _ws("w1", "i1", [("preview", "running")]),
        _ws("w2", "i2", [("preview", "running")]),
        _ws("w3", "i1", [("db", "running")]),
    ]


class PreviewTest(unittest.TestCase):
    def test_live_previews_only_non_stopped_preview_services(self):
        rows = _fixture() + [_ws("w4", "i4", [("preview", "stopped")])]
        self.assertEqual(preview.live_previews(rows), [("w1", "i1"), ("w2", "i2")])

    def test_sweep_stops_only_the_preview_of_finished_tickets(self):
        pc = StubPc(_fixture())
        status = {"i1": "done", "i2": "in_review"}.get

        self.assertEqual(preview.sweep(pc, status), ["w1"])
        self.assertEqual(pc.stops, [("w1", {"runtimeServiceId": "w1-preview"})])
        self.assertEqual([w for w, _ in pc.stops], ["w1"])  # w3 (db) never targeted

    def test_sweep_stops_cancelled_and_records_service_state_by_index(self):
        pc = StubPc([
            _ws("w5", "i5", [("web", "running"), ("preview", "running")],
                states={"0": "running", "1": "running"}),
        ])
        self.assertEqual(preview.sweep(pc, {"i5": "cancelled"}.get), ["w5"])
        self.assertEqual(pc.stops, [("w5", {"runtimeServiceId": "w5-preview"})])
        self.assertEqual(
            pc.patches,
            [("w5", {"config": {"serviceStates": {"0": "running", "1": "stopped"}}})],
        )

    def test_selector_falls_back_to_service_index_without_a_runtime_id(self):
        w = _ws("w6", "i6", [("preview", "running")], config_services=["web", "preview"])
        w["runtimeServices"][0].pop("id")
        pc = StubPc([w])
        self.assertEqual(preview.sweep(pc, {"i6": "done"}.get), ["w6"])
        self.assertEqual(pc.stops, [("w6", {"serviceIndex": 1})])

    def test_stopped_preview_with_running_state_is_recorded_not_stopped_again(self):
        w = _ws("w7", "i7", [("preview", "stopped")], states={"0": "running"})
        pc = StubPc([w])
        self.assertEqual(preview.sweep(pc, {"i7": "done"}.get), ["w7"])
        self.assertEqual(pc.stops, [])
        self.assertEqual(pc.patches, [("w7", {"config": {"serviceStates": {"0": "stopped"}}})])

    def test_stop_for_rework(self):
        pc = StubPc(_fixture())
        self.assertEqual(preview.stop_for_rework(pc, "i2"), ["w2"])
        self.assertEqual(pc.stops, [("w2", {"runtimeServiceId": "w2-preview"})])
        self.assertEqual(preview.stop_for_rework(StubPc(_fixture()), "i1"), ["w1"])

    def test_failed_stop_is_logged_and_the_sweep_continues(self):
        logs = []
        pc = StubPc(
            [_ws("w1", "i1", [("preview", "running")]), _ws("w2", "i2", [("preview", "running")])],
            fail_stop={"w1"},
        )
        done = preview.sweep(pc, lambda _id: "done", log=logs.append)
        self.assertEqual(done, ["w2"])
        self.assertTrue(any("w1" in line for line in logs))

    def test_list_failure_and_status_failure_do_not_raise(self):
        logs = []

        class Down(StubPc):
            def execution_workspaces(self, issue_id=None):
                raise paperclip.PaperclipError(0, "unreachable")

        self.assertEqual(preview.sweep(Down([]), lambda _i: "done", log=logs.append), [])
        self.assertEqual(preview.stop_for_rework(Down([]), "i1", log=logs.append), [])

        def boom(_id):
            raise paperclip.PaperclipError(404, "gone")

        pc = StubPc(_fixture())
        self.assertEqual(preview.sweep(pc, boom, log=logs.append), [])
        self.assertEqual(pc.stops, [])


if __name__ == "__main__":
    unittest.main()
