"""buzz CLI wrapper tests.

The wrapper is where identity and provenance touch the wire, so the tests pin:
one `--tag K=V` per tag, content on stdin (never argv), the key never in an
error string, and `BUZZ_AUTH_TAG` stripped from the child environment (that
attestation is bound to the front door's key; presenting it with another key
makes the CLI reject every command).
"""

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from opc_bridge import buzz, config


class _MemoryStore:
    def __init__(self):
        self.meta = {}

    def get_meta(self, key):
        return self.meta.get(key)

    def set_meta(self, key, value):
        self.meta[key] = value


class FakeRunner:
    def __init__(self):
        self.calls = []
        self.set_response(0, '{"event_id":"e1","accepted":true}', "")

    def set_response(self, rc, out, err=""):
        self.response = (rc, out, err)

    def __call__(self, argv, **kwargs):
        self.calls.append({"argv": argv, "input": kwargs.get("input"), "env": kwargs.get("env")})
        rc, out, err = self.response
        return SimpleNamespace(returncode=rc, stdout=out, stderr=err)

    @property
    def last(self):
        return self.calls[-1]


class BuzzClientTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.nsec_path = Path(tmp.name) / "paperclip.nsec"
        self.nsec_path.write_text("nsec1secretvalue")
        self.runner = FakeRunner()
        self.client = buzz.Buzz(
            "ws://buzz:3000",
            self.nsec_path,
            runner=self.runner,
            env={"PATH": "/usr/bin", "BUZZ_AUTH_TAG": "attestation", "BUZZ_PRIVATE_KEY": "leak"},
        )

    def test_send_passes_one_tag_flag_per_tag_and_reads_content_from_stdin(self):
        result = self.client.send(
            "c1",
            "hello",
            reply_to="a" * 64,
            tags={"opc-event": "evt_1", "opc-event-type": "paperclip.issue.completed"},
        )

        argv = self.runner.last["argv"]
        self.assertEqual(argv.count("--tag"), 2)
        self.assertIn("opc-event=evt_1", argv)
        self.assertEqual(argv[argv.index("--content") + 1], "-")
        self.assertEqual(argv[argv.index("--reply-to") + 1], "a" * 64)
        self.assertEqual(self.runner.last["input"], "hello")
        self.assertEqual((result.event_id, result.accepted), ("e1", True))

    def test_child_env_never_carries_the_owner_attestation_or_a_borrowed_key(self):
        self.client.send("c1", "x", None, {})

        env = self.runner.last["env"]
        self.assertNotIn("BUZZ_AUTH_TAG", env)
        self.assertNotIn("BUZZ_PRIVATE_KEY", env)
        # The identity is passed explicitly, never through the ambient env.
        argv = self.runner.last["argv"]
        self.assertEqual(argv[argv.index("--private-key") + 1], "nsec1secretvalue")

    def test_success_requires_an_accepted_event_with_an_id(self):
        self.runner.set_response(0, '{"event_id":"","accepted":true}', "")
        with self.assertRaises(buzz.BuzzError):
            self.client.send("c1", "x", None, {})

        self.runner.set_response(0, '{"event_id":"e1","accepted":false}', "")
        with self.assertRaises(buzz.BuzzError):
            self.client.send("c1", "x", None, {})

    def test_not_member_is_classified_from_the_relay_message(self):
        self.runner.set_response(
            2,
            "",
            '{"error":"relay_error","message":"relay error 400: restricted: not a channel member"}',
        )
        with self.assertRaises(buzz.BuzzError) as caught:
            self.client.send("c1", "x", None, {})
        self.assertEqual(caught.exception.kind, "not_member")

    def test_auth_failure_is_classified_by_exit_code(self):
        self.runner.set_response(3, "", '{"error":"auth_error","message":"signature failed"}')
        with self.assertRaises(buzz.BuzzError) as caught:
            self.client.send("c1", "x", None, {})
        self.assertEqual(caught.exception.kind, "auth")

    def test_errors_never_contain_the_key(self):
        self.runner.set_response(4, "", "boom")
        with self.assertRaises(buzz.BuzzError) as caught:
            self.client.send("c1", "x", None, {})
        self.assertNotIn("nsec1secretvalue", str(caught.exception))

    def test_invalid_tag_key_is_rejected_before_running_the_cli(self):
        with self.assertRaises(buzz.BuzzError) as caught:
            self.client.send("c1", "x", None, {"Bad Key": "v"})
        self.assertEqual(caught.exception.kind, "usage")
        self.assertEqual(self.runner.calls, [])

    def test_channels_and_messages_parse_json(self):
        self.runner.set_response(0, '[{"channel_id":"c1","name":"general"}]', "")
        self.assertEqual(self.client.channels()[0]["channel_id"], "c1")

        self.runner.set_response(0, '[{"id":"m1","content":"hi","pubkey":"p"}]', "")
        self.assertEqual(self.client.messages("c1", since=100, limit=5)[0]["id"], "m1")
        argv = self.runner.last["argv"]
        self.assertIn("--since", argv)
        self.assertEqual(argv[argv.index("--since") + 1], "100")

    def test_create_channel_uses_a_stream_open_channel(self):
        self.runner.set_response(0, '{"channel_id":"c9"}', "")
        self.client.create_channel("opc-control")

        argv = self.runner.last["argv"]
        self.assertIn("create", argv)
        self.assertEqual(argv[argv.index("--name") + 1], "opc-control")
        self.assertEqual(argv[argv.index("--type") + 1], "stream")
        self.assertEqual(argv[argv.index("--visibility") + 1], "open")

    def test_control_channel_prefers_env_then_name_then_creates(self):
        # 1) an explicit env value always wins
        cfg_env = config.load({"OPC_CONTROL_CHANNEL": "c-env"})
        store_env = _MemoryStore()
        self.assertEqual(buzz.resolve_control_channel(cfg_env, self.client, store_env), "c-env")
        self.assertEqual(store_env.meta["control_channel"], "c-env")

        # 2) otherwise the channel named opc-control, if it exists
        cfg = config.load({"OPC_CONTROL_CHANNEL": ""})
        store_named = _MemoryStore()
        self.runner.set_response(0, '[{"channel_id":"c7","name":"opc-control"}]', "")
        self.assertEqual(buzz.resolve_control_channel(cfg, self.client, store_named), "c7")
        self.assertEqual(store_named.meta["control_channel"], "c7")

        # 3) and if it does not, create it once and remember the id
        def list_or_create(argv, **kwargs):
            if "create" in argv:
                return SimpleNamespace(returncode=0, stdout='{"channel_id":"c8"}', stderr="")
            return SimpleNamespace(returncode=0, stdout="[]", stderr="")

        store_created = _MemoryStore()
        client = buzz.Buzz("ws://buzz:3000", self.nsec_path, runner=list_or_create, env={})
        self.assertEqual(buzz.resolve_control_channel(cfg, client, store_created), "c8")
        self.assertEqual(store_created.meta["control_channel"], "c8")

    def test_missing_key_file_fails_at_construction(self):
        with self.assertRaises(buzz.BuzzError) as caught:
            buzz.Buzz("ws://buzz:3000", Path("/nonexistent/paperclip.nsec"), runner=self.runner)
        self.assertEqual(caught.exception.kind, "key")


if __name__ == "__main__":
    unittest.main()
