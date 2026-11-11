#!/usr/bin/env python3
"""Run in the Hermes image: python tests/hermes-default-env.py <helper-path>."""
import importlib.util
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

from agent.secret_scope import load_env_file

spec = importlib.util.spec_from_file_location("opc_default_env", sys.argv.pop(1))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DefaultProfileEnvTest(unittest.TestCase):
    def test_rotation_preserves_editable_provider_and_unterminated_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text('API_SERVER_KEY=old-first\nexport API_SERVER_KEY = "old-last"\n'
                            'OPENAI_API_KEY="operator-provider"\nOTHER="keep"', encoding="utf-8")
            with patch.dict(os.environ, {"API_SERVER_KEY": 'rotated-"key\\value',
                                         "OPENAI_API_KEY": "stack-provider",
                                         "OPENAI_BASE_URL": "https://example.invalid/v1"}, clear=True):
                module.sync_default_env(path)
                self.assertEqual(load_env_file(path), {
                    "API_SERVER_KEY": 'rotated-"key\\value',
                    "OPENAI_API_KEY": "operator-provider", "OTHER": "keep",
                })
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                self.assertEqual(sum("API_SERVER_KEY" in line for line in path.read_text().splitlines()), 1)
                before = path.read_bytes(), path.stat().st_mtime_ns
                module.sync_default_env(path)
                self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)

    def test_revocation_does_not_resurrect_profile_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text("API_SERVER_KEY=revoked\nOPENAI_API_KEY=\n", encoding="utf-8")
            with patch.dict(os.environ, {"API_SERVER_KEY": "", "OPENAI_API_KEY": "stack-provider"}, clear=True):
                module.sync_default_env(path)
            self.assertEqual(load_env_file(path), {"API_SERVER_KEY": "", "OPENAI_API_KEY": ""})

    def test_fresh_seed_omits_empty_optional_provider_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            with patch.dict(os.environ, {"API_SERVER_KEY": "default-listener-key",
                                         "OPENAI_API_KEY": "default-model-key",
                                         "ANTHROPIC_API_KEY": ""}, clear=True):
                module.sync_default_env(path)
            self.assertEqual(load_env_file(path), {"API_SERVER_KEY": "default-listener-key",
                                                   "OPENAI_API_KEY": "default-model-key"})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_seeded_provider_rotation_reaches_the_effective_secret_scope(self):
        from agent.secret_scope import get_secret, reset_secret_scope, set_secret_scope

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            with patch.dict(os.environ, {"OPENAI_API_KEY": "old-provider-secret",
                                         "OPENAI_BASE_URL": "https://old.invalid/v1"}, clear=True):
                module.sync_default_env(path)
            with patch.dict(os.environ, {"OPENAI_API_KEY": "new-provider-secret",
                                         "OPENAI_BASE_URL": "https://new.invalid/v1"}, clear=True):
                self.assertTrue(module.sync_default_env(path))
                token = set_secret_scope(load_env_file(path))
                try:
                    self.assertEqual(get_secret("OPENAI_API_KEY"), "new-provider-secret")
                    self.assertEqual(get_secret("OPENAI_BASE_URL"), "https://new.invalid/v1")
                finally:
                    reset_secret_scope(token)
                module.sync_default_env(path)
            self.assertNotIn("old-provider-secret", (path.parent / ".opc-provider-seed.json").read_text())
            self.assertNotIn("new-provider-secret", (path.parent / ".opc-provider-seed.json").read_text())

    def test_operator_key_blocks_endpoint_cutover_without_disclosing_the_key(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            with patch.dict(os.environ, {"OPENAI_API_KEY": "stack-secret"}, clear=True):
                module.sync_default_env(path)
            path.write_text('OPENAI_API_KEY="operator-secret"\n')
            with patch.dict(os.environ, {"OPENAI_API_KEY": "replacement-secret"}, clear=True):
                self.assertFalse(module.sync_default_env(path))
            self.assertEqual(load_env_file(path)["OPENAI_API_KEY"], "operator-secret")

    def test_expert_provider_rotation_preserves_its_listener_and_other_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text('API_SERVER_KEY="expert-listener"\nCUSTOM_SECRET="keep"\n')
            with patch.dict(os.environ, {"API_SERVER_KEY": "default-listener",
                                         "OPENAI_API_KEY": "old-model-key"}, clear=True):
                module.sync_default_env(path, provider_only=True)
            with patch.dict(os.environ, {"OPENAI_API_KEY": "rotated-model-key"}, clear=True):
                self.assertTrue(module.sync_default_env(path, provider_only=True))
            self.assertEqual(load_env_file(path), {
                "API_SERVER_KEY": "expert-listener", "CUSTOM_SECRET": "keep",
                "OPENAI_API_KEY": "rotated-model-key",
            })

    def test_matching_preledger_value_is_adopted_and_can_be_revoked(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text('OPENAI_API_KEY="current-stack-key"\n')
            with patch.dict(os.environ, {"OPENAI_API_KEY": "current-stack-key"}, clear=True):
                module.sync_default_env(path)
            with patch.dict(os.environ, {"OPENAI_API_KEY": ""}, clear=True):
                self.assertTrue(module.sync_default_env(path))
            self.assertEqual(load_env_file(path)["OPENAI_API_KEY"], "")

    def test_operator_endpoint_or_key_blocks_the_entire_provider_pair(self):
        for edited_name, edited_value in (
            ("OPENAI_BASE_URL", "https://operator.invalid/v1"),
            ("OPENAI_API_KEY", "operator-secret"),
        ):
            with self.subTest(edited_name=edited_name), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / ".env"
                original = {"OPENAI_API_KEY": "old-provider-key",
                            "OPENAI_BASE_URL": "https://old.invalid/v1"}
                with patch.dict(os.environ, original, clear=True):
                    module.sync_default_env(path)
                before = dict(original, **{edited_name: edited_value})
                path.write_text("".join(f"{key}={value}\n" for key, value in before.items()))
                replacement = {"OPENAI_API_KEY": "new-provider-key",
                               "OPENAI_BASE_URL": "https://new.invalid/v1"}
                with patch.dict(os.environ, replacement, clear=True):
                    self.assertFalse(module.sync_default_env(path))
                self.assertEqual(load_env_file(path), before)
                # Hand back the original pair: a blocked cutover must not
                # consume its previous ownership record.
                path.write_text("".join(f"{key}={value}\n" for key, value in original.items()))
                with patch.dict(os.environ, replacement, clear=True):
                    self.assertTrue(module.sync_default_env(path))
                self.assertEqual(load_env_file(path), replacement)

    def test_compose_provider_credentials_authenticate_under_multiplex_scope(self):
        from agent.secret_scope import reset_secret_scope, set_multiplex_active, set_secret_scope
        from hermes_cli.auth import resolve_api_key_provider_credentials
        from hermes_constants import reset_hermes_home_override, set_hermes_home_override

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            with patch.dict(os.environ, {"DEEPSEEK_API_KEY": "deepseek-default-secret",
                                         "XAI_API_KEY": "xai-default-secret"}, clear=True):
                module.sync_default_env(path)
                home_token = set_hermes_home_override(directory)
                set_multiplex_active(True)
                scope_token = set_secret_scope(load_env_file(path), profile_home=directory)
                try:
                    self.assertEqual(resolve_api_key_provider_credentials("deepseek")["api_key"],
                                     "deepseek-default-secret")
                    self.assertEqual(resolve_api_key_provider_credentials("xai")["api_key"],
                                     "xai-default-secret")
                finally:
                    reset_secret_scope(scope_token)
                    set_multiplex_active(False)
                    reset_hermes_home_override(home_token)


if __name__ == "__main__":
    unittest.main()
