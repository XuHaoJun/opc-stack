#!/bin/sh
# Offline behavior checks; all files and processes belong to a throwaway home.
set -eu
cd "$(dirname "$0")/.."
python3 - "$@" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

LIB = str(Path('patches/hermes/opc-model-seed.sh').resolve())


class ModelSeedTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.env = dict(os.environ, OMP_CONFIG_DIR=str(self.home / '.omp'),
                        OPENAI_MODEL='deepseek/deepseek-v4.1-flash',
                        OPENAI_BASE_URL='https://provider.invalid/v1',
                        OMP_MODEL_CONTEXT_WINDOW='', OMP_MODEL_MAX_TOKENS='')
        self.agent = self.home / '.omp/agent'
        self.agent.mkdir(parents=True)

    def run_seed(self, command='opc_omp_seed', **updates):
        return subprocess.run(['sh', '-ceu', '. ' + shlex.quote(LIB) + '; ' + command],
                              env=dict(self.env, **updates), text=True, capture_output=True,
                              check=True)

    def field(self, path, key):
        return self.run_seed('opc_yaml_field ' + shlex.quote(str(path)) + ' ' + key).stdout.rstrip('\n')

    def test_legacy_model_and_endpoint_follow_then_preserve_operator_choice(self):
        cfg = self.home / 'config.yaml'
        cfg.write_text('model:\n  default: deepseek-v4.1-flash\n'
                       '  base_url: https://opencode.ai/zen/go/v1\n')
        command = ('opc_model_follow "$CFG" default "$OPENAI_MODEL" "$OPC_STACK_MODEL_DEFAULTS"; '
                   'opc_model_follow "$CFG" base_url "$OPENAI_BASE_URL" "$OPC_STACK_BASE_URL_DEFAULTS"')
        self.run_seed(command, CFG=str(cfg))
        self.assertEqual(self.field(cfg, 'default'), 'deepseek/deepseek-v4.1-flash')
        self.assertEqual(self.field(cfg, 'base_url'), 'https://provider.invalid/v1')
        cfg.write_text('model:\n  default: operator-model\n'
                       '  base_url: https://provider.invalid/v1\n')
        self.run_seed(command, CFG=str(cfg), OPENAI_MODEL='another-model')
        self.assertEqual(self.field(cfg, 'default'), 'operator-model')
        self.run_seed(command, CFG=str(cfg), OPENAI_MODEL='operator-model')
        self.run_seed(command, CFG=str(cfg), OPENAI_MODEL='reclaimed-model')
        self.assertEqual(self.field(cfg, 'default'), 'reclaimed-model')

    def test_custom_provider_values_survive_yaml_serialization_and_next_boot(self):
        # These are valid scalar data, not YAML tokens or escape sequences.
        for model in ('@cf/meta/llama-3.1-8b-instruct', "operator's/model\\version"):
            with self.subTest(model=model):
                self.run_seed(OPENAI_MODEL=model, OMP_MODEL_CONTEXT_WINDOW='200000',
                              OMP_MODEL_MAX_TOKENS='32000')
                lines = (self.agent / 'models.yml').read_text().splitlines()
                values = {}
                for line in lines:
                    key, sep, value = line.strip().removeprefix('- ').partition(': ')
                    if sep and key in ('id', 'name', 'baseUrl', 'apiKey'):
                        values[key] = json.loads(value)
                self.assertEqual(values, {'id': model, 'name': model,
                                         'baseUrl': 'https://provider.invalid/v1',
                                         'apiKey': 'OPENAI_API_KEY'})
                self.assertEqual(self.field(self.agent / 'config.yml', 'default'), 'opc/' + model)
        self.run_seed(OPENAI_MODEL='following-model')
        self.assertEqual(self.field(self.agent / 'config.yml', 'default'), 'opc/following-model')

    def test_legacy_omp_role_migrates_without_dropping_unrelated_settings(self):
        cfg = self.agent / 'config.yml'
        cfg.write_text('modelRoles:\n  default: opencode-go/deepseek-v4.1-flash\n'
                       'startup:\n  quiet: false\n')
        self.run_seed()
        self.assertEqual(self.field(cfg, 'default'), 'opc/deepseek/deepseek-v4.1-flash')
        self.assertIn('startup:\n  quiet: false\n', cfg.read_text())
        self.run_seed(OPENAI_MODEL='replacement-model')
        self.assertEqual(self.field(cfg, 'default'), 'opc/replacement-model')

    def test_operator_provider_files_are_never_shadowed_or_assigned_an_absent_provider(self):
        for suffix in ('yml', 'yaml', 'json'):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as directory:
                agent = Path(directory) / 'agent'
                agent.mkdir()
                path = agent / ('models.' + suffix)
                original = '{"providers":{"operator":{"baseUrl":"https://operator.invalid/v1"}}}\n'
                path.write_text(original)
                self.run_seed(OMP_CONFIG_DIR=directory)
                self.assertEqual(path.read_text(), original)
                if suffix != 'yml':
                    self.assertFalse((agent / 'models.yml').exists())
                self.assertFalse((agent / 'config.yml').exists())

    def test_operator_yaml_role_config_is_not_shadowed(self):
        cfg = self.agent / 'config.yaml'
        original = '{"modelRoles":{"default":"operator/chosen"}}\n'
        cfg.write_text(original)
        self.run_seed()
        self.assertEqual(cfg.read_text(), original)
        self.assertFalse((self.agent / 'config.yml').exists())

    def test_yaml_specific_escapes_preserve_operator_choice_and_allow_handback(self):
        cfg = self.home / 'config.yaml'
        original = 'model:\n  default: "\\x40cf/meta/operator"\n'
        cfg.write_text(original)
        command = 'opc_model_follow "$CFG" default "$OPENAI_MODEL" "$OPC_STACK_MODEL_DEFAULTS"'
        self.run_seed(command, CFG=str(cfg))
        self.assertEqual(cfg.read_text(), original)
        self.assertEqual(self.field(cfg, 'default'), '@cf/meta/operator')
        self.run_seed(command, CFG=str(cfg), OPENAI_MODEL='@cf/meta/operator')
        self.run_seed(command, CFG=str(cfg), OPENAI_MODEL='replacement-model')
        self.assertEqual(self.field(cfg, 'default'), 'replacement-model')

    def test_operator_edits_stop_provider_rewrites(self):
        self.run_seed()
        path = self.agent / 'models.yml'
        original = '{"providers":{"operator":{"baseUrl":"https://operator.invalid/v1"}}}\n'
        path.write_text(original)
        cfg = self.agent / 'config.yml'
        before = cfg.read_bytes()
        self.run_seed(OPENAI_MODEL='replacement-model')
        self.assertEqual(path.read_text(), original)
        self.assertEqual(cfg.read_bytes(), before)

    def test_model_transaction_waits_for_the_shared_ledger_lock(self):
        cfg = self.home / 'config.yaml'
        cfg.write_text('model:\n  default: deepseek-v4.1-flash\n')
        with (self.home / '.opc-model-seed.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            command = ('. ' + shlex.quote(LIB) + '; echo started; '
                       'opc_model_follow "$CFG" default "$OPENAI_MODEL" "$OPC_STACK_MODEL_DEFAULTS"')
            proc = subprocess.Popen(['sh', '-ceu', command], env=dict(self.env, CFG=str(cfg)),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertEqual(proc.stdout.readline(), 'started\n')
                with self.assertRaises(subprocess.TimeoutExpired):
                    proc.wait(timeout=0.2)
                fcntl.flock(lock, fcntl.LOCK_UN)
                stdout, stderr = proc.communicate(timeout=5)
                self.assertEqual(proc.returncode, 0, stderr)
                self.assertEqual(self.field(cfg, 'default'), 'deepseek/deepseek-v4.1-flash')
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.communicate()

    def test_simultaneous_provider_and_role_writers_publish_consistent_state(self):
        command = '. ' + shlex.quote(LIB) + '; opc_omp_seed'
        processes = [subprocess.Popen(['sh', '-ceu', command], env=self.env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for _ in range(8)]
        try:
            results = [(proc, proc.communicate(timeout=15)) for proc in processes]
        finally:
            for proc in processes:
                if proc.poll() is None:
                    proc.kill()
                proc.communicate()
        for proc, (stdout, stderr) in results:
            self.assertEqual(proc.returncode, 0, stderr)
        self.assertEqual(self.field(self.agent / 'config.yml', 'default'),
                         'opc/deepseek/deepseek-v4.1-flash')
        before = (self.agent / 'models.yml').read_bytes()
        self.run_seed(OPENAI_MODEL='post-race-model')
        self.assertNotEqual((self.agent / 'models.yml').read_bytes(), before)
        self.assertEqual(self.field(self.agent / 'config.yml', 'default'), 'opc/post-race-model')


unittest.main(verbosity=2)
PY
