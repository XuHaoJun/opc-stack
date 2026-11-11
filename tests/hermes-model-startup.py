#!/usr/bin/env python3
"""Exercise patched startup in a disposable image; no network or persistent volumes."""
from pathlib import Path
import subprocess


SCENARIO = r'''
import os
from pathlib import Path
import subprocess
import tempfile

import hermes_yaml
from agent.secret_scope import get_secret, load_env_file, reset_secret_scope, set_secret_scope

for target, source in SOURCES.items():
    path = Path(target)
    path.write_text(source)
    path.chmod(0o755)
# Isolate unrelated external provisioning, not the model or credential code.
for name, function in [('opc-nix-seed.sh', 'opc_nix_seed'),
                       ('opc-mise-seed.sh', 'opc_mise_seed'),
                       ('opc-gh-seed.sh', 'opc_gh_seed')]:
    Path('/usr/local/bin', name).write_text(function + '() { :; }\n')
dispatch = Path('/opt/hermes/docker/entrypoint-dispatch.sh')
dispatch.write_text('#!/bin/sh\nexit 0\n')
dispatch.chmod(0o755)
Path('/keys').mkdir(exist_ok=True)
for name in ('paperclip-api.key', 'tencentdb-admin-user-id', 'scientist.nsec'):
    Path('/keys', name).write_text('fixture-only-nonproduction-value')

with tempfile.TemporaryDirectory(prefix='opc-startup-regression-') as directory:
    root = Path(directory)
    root.chmod(0o755)

    def boot(home, command, model, key, base):
        home.mkdir(exist_ok=True)
        env = dict(os.environ, HERMES_HOME=str(home), OPENAI_MODEL=model,
                   OPENAI_API_KEY=key, OPENAI_BASE_URL=base,
                   HERMES_SCIENTIST_API_KEY='fixture-listener-key-123456')
        result = subprocess.run(['/usr/local/bin/hermes-entrypoint.sh', command], env=env,
                                capture_output=True, text=True, timeout=90)
        assert result.returncode == 0, (result.stdout, result.stderr)

    front = root / 'frontdoor'
    front.mkdir()
    (front / 'config.yaml').write_text('_config_version: 52\nmodel:\n  provider: custom\n'
        '  api_key: ${OPENAI_API_KEY}\n  default: frontdoor-only-model\n'
        '  base_url: https://old.invalid/v1\n')
    (front / '.opc-model-seed').write_text('default=frontdoor-only-model\n'
                                         'base_url=https://old.invalid/v1\n')
    boot(front, 'dashboard', 'shared-model', 'fixture-stack-key', 'https://new.invalid/v1')
    model = hermes_yaml.safe_load((front / 'config.yaml').read_text())['model']
    assert model['default'] == 'frontdoor-only-model', model
    assert model['base_url'] == 'https://old.invalid/v1', model
    assert not (front / '.env').exists()
    print('PASS dashboard preserves frontdoor model, endpoint and scoped credentials')

    empty = root / 'empty-frontdoor'
    boot(empty, 'dashboard', 'shared-model', 'fixture-stack-key', 'https://new.invalid/v1')
    assert not (empty / 'config.yaml').exists()
    print('PASS dashboard does not claim fresh frontdoor model ownership')

    gateway = root / 'gateway'
    boot(gateway, 'gateway', '@cf/meta/llama-3.1-8b-instruct',
         'old-fixture-model-key', 'https://old.invalid/v1')
    homes = (gateway, gateway / 'profiles/agt-scientist')
    for home in homes:
        model = hermes_yaml.safe_load((home / 'config.yaml').read_text())['model']
        assert model['default'] == '@cf/meta/llama-3.1-8b-instruct', model
    boot(gateway, 'gateway', 'new-fixture-model', 'new-fixture-model-key', 'https://new.invalid/v1')
    for home in homes:
        model = hermes_yaml.safe_load((home / 'config.yaml').read_text())['model']
        assert model['default'] == 'new-fixture-model', model
        assert model['base_url'] == 'https://new.invalid/v1', model
        token = set_secret_scope(load_env_file(home / '.env'))
        try:
            assert get_secret('OPENAI_API_KEY') == 'new-fixture-model-key'
        finally:
            reset_secret_scope(token)
    print('PASS default and expert endpoint/model/key cut over together')

    envpath = homes[1] / '.env'
    envpath.write_text(envpath.read_text().replace('new-fixture-model-key', 'operator-fixture-key'))
    boot(gateway, 'gateway', 'third-fixture-model', 'third-fixture-key', 'https://third.invalid/v1')
    model = hermes_yaml.safe_load((homes[1] / 'config.yaml').read_text())['model']
    assert model['default'] == 'new-fixture-model', model
    assert model['base_url'] == 'https://new.invalid/v1', model
    assert load_env_file(envpath)['OPENAI_API_KEY'] == 'operator-fixture-key'
    print('PASS operator key prevents endpoint cutover and is preserved')

    default_env = gateway / '.env'
    default_env.write_text(default_env.read_text().replace(
        'https://third.invalid/v1', 'https://operator.invalid/v1'))
    boot(gateway, 'gateway', 'fourth-model', 'fourth-key', 'https://fourth.invalid/v1')
    model = hermes_yaml.safe_load((gateway / 'config.yaml').read_text())['model']
    assert model['base_url'] == 'https://third.invalid/v1', model
    assert model['default'] == 'third-fixture-model', model
    assert load_env_file(default_env)['OPENAI_API_KEY'] == 'third-fixture-key'
    assert load_env_file(default_env)['OPENAI_BASE_URL'] == 'https://operator.invalid/v1'
    print('PASS operator endpoint blocks key rotation before publishing a mixed pair')
'''


def main():
    repo = Path(__file__).resolve().parents[1]
    image = subprocess.check_output(['docker', 'compose', 'images', '-q', 'hermes'],
                                    cwd=repo, text=True).strip()
    if not image:
        raise SystemExit('Build the Hermes image before running this gate.')
    sources = {
        '/usr/local/bin/hermes-entrypoint.sh': (repo / 'patches/hermes/hermes-entrypoint.sh').read_text(),
        '/usr/local/bin/opc-model-seed.sh': (repo / 'patches/hermes/opc-model-seed.sh').read_text(),
        '/usr/local/lib/opc-default-env.py': (repo / 'patches/hermes/opc-default-env.py').read_text(),
    }
    subprocess.run(['docker', 'run', '--rm', '--network', 'none', '--user', '0',
                    '--entrypoint', '/opt/hermes/.venv/bin/python', image,
                    '-c', 'SOURCES = ' + repr(sources) + '\n' + SCENARIO],
                   cwd=repo, check=True, timeout=240)


if __name__ == '__main__':
    main()
