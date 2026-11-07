"""HTTP surface tests.

One rule carries the security model: `/v1/health` is open (so a container
healthcheck needs no secret) and everything else requires the bearer key before
routing happens — an unknown path must answer 401, not 404, so the API's shape
is not enumerable without the key.
"""

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from opc_bridge import api, config, store


class ApiTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.key_path = Path(tmp.name) / "opc-control.key"
        self.key_path.write_text("right")
        self.notifier = Path(tmp.name) / "paperclip.nsec"
        self.notifier.write_text("nsec1test")
        self.board = Path(tmp.name) / "paperclip-api.key"
        self.board.write_text("board")
        self.cfg = config.load(
            {
                "OPC_DB_PATH": str(Path(tmp.name) / "b.db"),
                "OPC_API_KEY_FILE": str(self.key_path),
                "OPC_NOTIFIER_NSEC": str(self.notifier),
                "PAPERCLIP_API_KEY_FILE": str(self.board),
            }
        )
        self.store = store.Store(self.cfg.db_path)
        self.addCleanup(self.store.close)

        self.api = api.Api(self.cfg, self.store)
        self.server = self.api.make_server(("127.0.0.1", 0))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        host, port = self.server.server_address[:2]
        self.base = f"http://{host}:{port}"

    def get(self, path, key=None):
        request = urllib.request.Request(self.base + path)
        if key:
            request.add_header("Authorization", f"Bearer {key}")
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read() or b"{}")

    def test_health_is_open_and_reports_the_schema(self):
        status, body = self.get("/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["schema_version"], store.SCHEMA_VERSION)

    def test_unknown_route_without_the_key_is_401_not_404(self):
        status, _ = self.get("/v1/policy/effective")
        self.assertEqual(status, 401)

    def test_unknown_route_with_the_key_is_404(self):
        status, _ = self.get("/v1/policy/effective", key="right")
        self.assertEqual(status, 404)

    def test_wrong_key_is_401(self):
        status, _ = self.get("/v1/events", key="wrong")
        self.assertEqual(status, 401)

    def test_health_reports_missing_dependencies(self):
        broken = config.load(
            {
                "OPC_DB_PATH": str(self.cfg.db_path),
                "OPC_API_KEY_FILE": "/nonexistent/key",
                "OPC_NOTIFIER_NSEC": str(self.notifier),
                "PAPERCLIP_API_KEY_FILE": str(self.board),
            }
        )
        server = api.Api(broken, self.store).make_server(("127.0.0.1", 0))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        host, port = server.server_address[:2]

        with urllib.request.urlopen(f"http://{host}:{port}/v1/health", timeout=5) as response:
            body = json.loads(response.read())

        self.assertEqual(body["status"], "degraded")
        self.assertIn("api_key", body["missing"])


if __name__ == "__main__":
    unittest.main()
