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
                    "OPENAI_BASE_URL": "https://example.invalid/v1",
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
