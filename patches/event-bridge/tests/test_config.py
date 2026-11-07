"""Config defaults and the injectable clock.

Every value must have a default: a missing env var is a working service, not a
crash on boot. The clock matters because health thresholds are time-based and
the tests must not wait 30 minutes.
"""

import unittest

from opc_bridge import config


class ConfigTest(unittest.TestCase):
    def test_empty_environment_still_produces_a_usable_config(self):
        cfg = config.load({})

        self.assertEqual(cfg.db_path.as_posix(), "/var/lib/opc-bridge/bridge.db")
        self.assertEqual(cfg.paperclip_api_url, "http://paperclip:3100")
        self.assertEqual(cfg.relay_url, "ws://buzz:3000")
        self.assertEqual(cfg.poll_interval, 7.0)
        self.assertEqual(cfg.max_attempts, 12)
        self.assertEqual(cfg.api_listen, ("0.0.0.0", 8645))
        self.assertEqual(cfg.core_selectors, ("role:engineer",))
        self.assertEqual(cfg.lab_selectors, ("name:Prototyper", "name:Scientist"))
        self.assertEqual((cfg.alloc_core, cfg.alloc_lab), (70, 30))
        self.assertEqual(cfg.slow_seconds, 900)
        self.assertEqual(cfg.stall_seconds, 1800)
        self.assertIsNone(cfg.test_now)

    def test_env_overrides_are_parsed_with_types(self):
        cfg = config.load(
            {
                "OPC_EVENT_POLL_INTERVAL": "2.5",
                "OPC_EVENT_MAX_ATTEMPTS": "3",
                "OPC_ALLOC_CORE": "100",
                "OPC_ALLOC_LAB": "0",
                "OPC_TRACK_LAB_AGENTS": "name:Prototyper, name:Scientist",
                "OPC_CONTROL_CHANNEL": "11111111-1111-1111-1111-111111111111",
                "OPC_EVENT_FALLBACK_CHANNEL": "",
                "OPC_TEST_NOW": "1791886698",
            }
        )

        self.assertEqual(cfg.poll_interval, 2.5)
        self.assertEqual(cfg.max_attempts, 3)
        self.assertEqual((cfg.alloc_core, cfg.alloc_lab), (100, 0))
        self.assertEqual(cfg.lab_selectors, ("name:Prototyper", "name:Scientist"))
        self.assertEqual(cfg.control_channel, "11111111-1111-1111-1111-111111111111")
        self.assertIsNone(cfg.fallback_channel)
        self.assertEqual(config.now(cfg), 1791886698.0)

    def test_clock_uses_wall_time_without_the_test_override(self):
        cfg = config.load({})
        self.assertGreater(config.now(cfg), 1_700_000_000)

    def test_api_listen_rejects_a_malformed_value(self):
        with self.assertRaises(ValueError):
            config.load({"OPC_API_LISTEN": "nope"})
