#!/usr/bin/env python3
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor


REPO = Path(__file__).resolve().parents[1]
OPERATOR = REPO / 'scripts/opc-assets'
HELPER = REPO / 'patches/paperclip/worktree-assets/asset-store.py'
IMAGE_ID = 'sha256:' + 'a' * 64
PROJECT = 'resolved-test'
VOLUME = 'explicitly-named-test-volume'
IMAGE = 'fixture/paperclip:built'
TOKEN = 'a' * 32


def helper():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('asset_store', HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def archive(*entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.GNU_FORMAT) as tar:
        for name, kind, data in entries:
            item = tarfile.TarInfo(name)
            item.type = kind
            item.mode = 0o777
            if kind == tarfile.REGTYPE:
                item.size = len(data)
                tar.addfile(item, io.BytesIO(data))
            else:
                if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                    item.linkname = data
                tar.addfile(item)
    stream.seek(0)
    return stream


def fake_docker(args):
    # The only stand-in is Docker transport. The helpers perform real filesystem
    # operations in the fixture volume, with the same arguments as production.
    if args == ['compose', 'config', '--format', 'json']:
        print(json.dumps({'name': PROJECT, 'services': {'paperclip': {'image': IMAGE}},
                          'volumes': {'opc-assets': {'name': VOLUME}}}))
        return 0
    if args == ['volume', 'ls', '--quiet', '--filter', f'label=com.docker.compose.project={PROJECT}',
                '--filter', 'label=com.docker.compose.volume=opc-assets']:
        print(os.environ.get('FIXTURE_VOLUMES', VOLUME))
        return 0
    if args == ['image', 'inspect', '--format', '{{.Id}}', IMAGE]:
        print(IMAGE_ID)
        return 0
    if args and args[0] == 'create':
        print('c' * 64)
        return 0
    if args[:2] == ['volume', 'inspect'] and args[-1] == VOLUME:
        print(os.environ.get('FIXTURE_ATTACHED_LABELS', f'{PROJECT}|opc-assets'))
        return 0
    if args == ['rm', 'c' * 64]:
        return 0
    if args and args[0] == 'run':
        index = args.index(IMAGE_ID)
        cli = args[index + 1:]
        command = cli[1]
        flags = {'stage': ['-i'], 'retire': ['-it']}.get(command, [])
        mount = f'type=volume,source={VOLUME},target=/opt/opc-assets,volume-nocopy'
        if command == 'list':
            mount += ',readonly'
        user = 'root' if command == 'init' else 'node'
        expected = ['run', '--pull=never', '--rm', '--network', 'none', '--mount', mount,
                    '--user', user, '--entrypoint', '/usr/bin/python3', *flags, IMAGE_ID,
                    '/usr/local/lib/opc-assets/asset-store.py']
        if args[:index + 2] != expected:
            raise AssertionError(f'unexpected helper isolation or image: {args!r}')
        rc = helper().main(cli[1:], root=Path(os.environ['FIXTURE_VOLUME_ROOT']),
                           runtime_identity=(os.getuid(), os.getgid()))
        with open(os.environ['FIXTURE_RUN_LOG'], 'a', encoding='utf-8') as log:
            print(command, rc, file=log)
        return rc
    raise AssertionError(f'unexpected Docker request: {args!r}')


class StoreTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.scratch = Path(scratch.name)
        self.root = self.scratch / 'volume'
        self.root.mkdir()
        self.source = self.scratch / 'host source'
        self.source.mkdir()
        self.revisions = self.root / 'sample' / 'revisions'
        self.bin = self.scratch / 'bin'
        self.bin.mkdir()
        self.log = self.scratch / 'run.log'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        FIXTURE_VOLUME_ROOT=str(self.root), FIXTURE_RUN_LOG=str(self.log))
        self.wrapper('docker', f'exec {shlex.quote(sys.executable)} '
                     f'{shlex.quote(str(Path(__file__).resolve()))} --fixture-docker "$@"')

    def wrapper(self, name, text):
        path = self.bin / name
        path.write_text(f'#!/bin/sh\n{text}\n', encoding='utf-8')
        path.chmod(0o755)

    def operator(self, *args, **env):
        return subprocess.run([OPERATOR, *args], cwd=self.scratch, env={**self.env, **env},
                              text=True, capture_output=True, timeout=15)

    def import_one(self, data):
        (self.source / 'asset').write_bytes(data)
        result = self.operator('import', 'sample', self.source.name, 'asset')
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def staged(self, stream, token=TOKEN):
        store = helper()
        store.initialize(self.root, 'sample', os.getuid(), os.getgid())
        return store.stage(self.root, 'sample', token, stream)

    def test_usage_needs_a_command_before_contacting_docker(self):
        result = self.operator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('usage:', result.stderr.lower())
        self.assertEqual(list(self.root.iterdir()), [])

    def test_refuses_missing_ambiguous_and_stale_volume_labels(self):
        for candidates in ('', f'{VOLUME}\nother', 'other'):
            with self.subTest(candidates=candidates):
                result = self.operator('list', FIXTURE_VOLUMES=candidates)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('volume', result.stderr.lower())
                self.assertFalse(self.log.exists())

    def test_refuses_volume_replaced_during_attachment(self):
        (self.source / 'asset').write_bytes(b'host data')
        result = self.operator('import', 'sample', self.source.name, 'asset', FIXTURE_ATTACHED_LABELS='|')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())
        self.assertEqual(list(self.root.iterdir()), [])

    def test_list_of_uninitialized_volume_leaves_it_empty(self):
        result = self.operator('list')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('logical_bytes', result.stdout)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_import_is_canonical_across_order_and_metadata(self):
        tree = self.source / 'Data'
        tree.mkdir()
        (tree / 'empty').mkdir(mode=0o700)
        (tree / 'é').write_bytes(b'hello')
        (tree / 'é').chmod(0o700)
        (self.source / '-other').write_bytes(b'')
        (self.source / 'unselected').write_text('do not import', encoding='utf-8')
        inventory = (
            '[["f","-other","e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"],'
            '["d","Data"],["d","Data/empty"],'
            '["f","Data/é","2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"]]'
        ).encode('utf-8')
        expected = 'sha256:' + hashlib.sha256(inventory).hexdigest()
        result = self.operator('import', 'sample', self.source.name, 'Data', '-other')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected + '\n')
        path = self.revisions / expected.removeprefix('sha256:')
        self.assertEqual((path / 'inventory.json').read_bytes(), inventory)
        self.assertEqual((path / 'payload/Data/é').read_bytes(), b'hello')
        self.assertEqual(stat.S_IMODE((path / 'payload/Data/é').stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE((path / 'payload/Data/empty').stat().st_mode), 0o755)
        self.assertFalse((path / 'payload/unselected').exists())
        inode = path.stat().st_ino
        (tree / 'é').chmod(0o600)
        result = self.operator('import', 'sample', self.source.name, '-other', 'Data')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected + '\n')
        self.assertEqual(path.stat().st_ino, inode)
        self.assertEqual(list(self.root.joinpath('.staging').iterdir()), [])

    def test_long_utf8_name_and_payload_larger_than_stream_buffer_round_trip(self):
        name = 'é' * 80
        content = bytes(range(256)) * 4501
        (self.source / name).write_bytes(content)
        result = self.operator('import', 'sample', self.source.name, name)
        self.assertEqual(result.returncode, 0, result.stderr)
        revision = self.revisions / result.stdout.strip().removeprefix('sha256:')
        self.assertEqual((revision / 'payload' / name).read_bytes(), content)
        self.assertEqual(json.loads((revision / 'inventory.json').read_bytes()),
                         [['f', name, hashlib.sha256(content).hexdigest()]])

    def test_producer_failure_after_complete_archive_never_publishes(self):
        previous = self.import_one(b'previous')
        (self.source / 'asset').write_bytes(b'new')
        self.wrapper('python3', f'{shlex.quote(sys.executable)} "$@" || exit "$?"\n'
                     'if [ "$2" = pack ]; then exit 73; fi\nexit 0')
        self.log.unlink()
        result = self.operator('import', 'sample', self.source.name, 'asset')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('stage 0', self.log.read_text(encoding='utf-8'))
        self.assertEqual([p.name for p in self.revisions.iterdir()], [previous.removeprefix('sha256:')])
        self.assertEqual(list(self.root.joinpath('.staging').iterdir()), [])

    def test_host_rejects_symlink_hardlink_fifo_and_invalid_utf8(self):
        target = self.source / 'target'
        target.write_bytes(b'must not be read through aliases')
        (self.source / 'symbolic').symlink_to(target)
        os.link(target, self.source / 'hard')
        os.mkfifo(self.source / 'fifo')
        with open(os.fsencode(self.source) + b'/invalid\xff', 'wb'):
            pass
        for entry in ('symbolic', 'hard', 'fifo', 'invalid\udcff', '../target', 'target/child'):
            with self.subTest(entry=entry):
                result = self.operator('import', 'sample', self.source.name, entry)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
        self.assertEqual(list(self.revisions.iterdir()), [])

    def test_unsafe_archive_members_are_never_written_or_published(self):
        file_type = tarfile.REGTYPE
        regular = ('legit', file_type, b'legit')
        cases = [
            (regular, ('../escaped', file_type, b'oops')),
            (regular, (str(self.scratch / 'escaped'), file_type, b'oops')),
            (regular, ('dir//child', file_type, b'oops')),
            (regular, ('dir/../escaped', file_type, b'oops')),
            (regular, ('.GiT', tarfile.DIRTYPE, None)),
            (regular, ('aliased', tarfile.SYMTYPE, str(self.scratch))),
            (regular, ('aliased', tarfile.LNKTYPE, 'legit')),
            (regular, ('fifo', tarfile.FIFOTYPE, None)),
            (regular, ('port', tarfile.CHRTYPE, None)),
            (regular, ('bogus', b'Z', None)),
            (regular, ('legit', file_type, b'overwrite')),
            (regular, ('legit/child', file_type, b'oops')),
            (('empty', tarfile.DIRTYPE, None), ('empty', tarfile.DIRTYPE, None)),
            (('path\udcff', file_type, b'not utf-8'),),
        ]
        for members in cases:
            with self.subTest(members=members):
                with self.assertRaises(ValueError):
                    self.staged(archive(*members))
                self.assertFalse((self.scratch / 'escaped').exists())
                self.assertEqual(list(self.revisions.iterdir()), [])
                self.assertEqual(list(self.root.joinpath('.staging').iterdir()), [])

    def test_rejects_missing_end_marker_bad_checksum_and_concatenated_tar(self):
        good = archive(('asset', tarfile.REGTYPE, b'x')).getvalue()
        for bad in (good[:1024], good[:1536], good[:1024] + b'a' * 512 + good[1536:], good + good):
            with self.subTest(size=len(bad)):
                with self.assertRaises(ValueError):
                    self.staged(io.BytesIO(bad))
                self.assertEqual(list(self.revisions.iterdir()), [])
                self.assertEqual(list(self.root.joinpath('.staging').iterdir()), [])

    def test_cannot_publish_unfinished_or_retarget_a_completed_stage(self):
        revision = self.staged(archive(('asset', tarfile.REGTYPE, b'first')))
        store = helper()
        store.initialize(self.root, 'other', os.getuid(), os.getgid())
        with self.assertRaises(ValueError):
            store.publish(self.root, 'other', TOKEN, revision)
        with self.assertRaises(ValueError):
            store.publish(self.root, 'sample', TOKEN, 'sha256:' + '0' * 64)
        with self.assertRaises(ValueError):
            store.publish(self.root, 'sample', 'b' * 32, revision)
        (self.root / '.staging' / TOKEN / 'complete').unlink()
        with self.assertRaises(ValueError):
            store.publish(self.root, 'sample', TOKEN, revision)
        self.assertEqual(list(self.revisions.iterdir()), [])

    def test_cleanup_only_removes_the_requested_abandoned_token(self):
        self.staged(archive(('asset', tarfile.REGTYPE, b'kept')))
        staging = self.root / '.staging'
        abandoned = staging / ('b' * 32)
        abandoned.mkdir()
        (abandoned / 'unfinished').write_bytes(b'partially streamed content')
        store = helper()
        with self.assertRaises(ValueError):
            store.cleanup(self.root, '../sample')
        store.cleanup(self.root, abandoned.name)
        self.assertFalse(abandoned.exists())
        self.assertTrue((staging / TOKEN / 'complete').is_file())

    def test_bootstrap_never_follows_a_staging_symlink(self):
        outside = self.scratch / 'outside'
        outside.mkdir(mode=0o755)
        (self.root / '.staging').symlink_to(outside)
        result = self.operator('import', 'sample', self.source.name, 'asset')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertEqual(stat.S_IMODE(outside.stat().st_mode), 0o755)

    def test_concurrent_duplicate_publish_does_not_clobber(self):
        tokens = [TOKEN, 'b' * 32]
        revisions = [self.staged(archive(('asset', tarfile.REGTYPE, b'first')), token) for token in tokens]
        self.assertEqual(revisions[0], revisions[1])
        self.assertEqual(list(self.revisions.iterdir()), [])
        store = helper()
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(store.publish, self.root, 'sample', token, revision)
                       for token, revision in zip(tokens, revisions)]
            self.assertCountEqual([future.result(timeout=10) for future in futures], ['published', 'existing'])
        self.assertEqual(len(list(self.revisions.iterdir())), 1)
        self.assertEqual(list(self.root.joinpath('.staging').iterdir()), [])

    def test_duplicate_digest_refuses_missing_and_changed_published_payload(self):
        digest = self.import_one(b'first')
        file = self.revisions / digest.removeprefix('sha256:') / 'payload/asset'
        for damaged in (None, b'alt!!'):
            if damaged is None:
                file.unlink()
            else:
                file.write_bytes(damaged)
            result = self.operator('import', 'sample', self.source.name, 'asset')
            self.assertNotEqual(result.returncode, 0, result.stderr)
            if damaged is None:
                self.assertFalse(file.exists())
            else:
                self.assertEqual(file.read_bytes(), damaged)

    def test_publish_never_replaces_an_existing_empty_revision_directory(self):
        revision = self.staged(archive(('asset', tarfile.REGTYPE, b'first')))
        unexpected = self.revisions / revision.removeprefix('sha256:')
        unexpected.mkdir()
        inode = unexpected.stat().st_ino
        with self.assertRaises((ValueError, OSError)):
            helper().publish(self.root, 'sample', TOKEN, revision)
        self.assertEqual(unexpected.stat().st_ino, inode)
        self.assertEqual(list(unexpected.iterdir()), [])

    def tty_retire(self, revision, answer, *, after_preview=None):
        master, slave = pty.openpty()
        child = subprocess.Popen([OPERATOR, 'retire', 'sample', revision], cwd=self.scratch,
                                 env=self.env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        data = b''
        try:
            while b'Enter the full digest' not in data:
                self.assertTrue(select.select([master], [], [], 15)[0], data)
                try:
                    data += os.read(master, 4096)
                except OSError:
                    self.fail(f'retire exited before prompting: {data!r}')
            if after_preview is not None:
                after_preview()
            os.write(master, answer.encode() + b'\n')
            child.wait(timeout=15)
            return child.returncode, data.decode()
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            os.close(master)

    def test_retire_noninteractive_or_partial_digest_leaves_revision(self):
        revision = self.import_one(b'first')
        for requested in (revision[:15], revision):
            result = self.operator('retire', 'sample', requested)
            self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.revisions / revision.removeprefix('sha256:')).is_dir())

    def test_retire_previews_and_requires_exact_confirmation(self):
        first = self.import_one(b'five!')
        second = self.import_one(b'other!')
        self.assertNotEqual(first, second)
        before = self.operator('list', 'sample')
        self.assertEqual(before.returncode, 0, before.stderr)
        self.assertIn(f'sample\t{first}\t5', before.stdout)
        self.assertIn(f'sample\t{second}\t6', before.stdout)
        rc, preview = self.tty_retire(first, second)
        self.assertNotEqual(rc, 0)
        for expected in (PROJECT, VOLUME, first, '5 logical bytes', 'maintenance', 'backup'):
            self.assertIn(expected, preview)
        self.assertEqual(self.operator('list', 'sample').stdout, before.stdout)
        rc, preview = self.tty_retire(first, first)
        self.assertEqual(rc, 0, preview)
        after = self.operator('list', 'sample')
        self.assertEqual(after.returncode, 0, after.stderr)
        self.assertNotIn(first, after.stdout)
        self.assertIn(second, after.stdout)
        self.assertFalse((self.revisions / first.removeprefix('sha256:')).exists())

    def test_retire_does_not_delete_a_revision_replaced_after_preview(self):
        revision = self.import_one(b'five!')
        published = self.revisions / revision.removeprefix('sha256:')
        moved = self.scratch / 'moved'

        def replace():
            published.rename(moved)
            shutil.copytree(moved, published)

        rc, preview = self.tty_retire(revision, revision, after_preview=replace)
        self.assertNotEqual(rc, 0, preview)
        self.assertEqual((published / 'payload' / 'asset').read_bytes(), b'five!')


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--fixture-docker':
        sys.exit(fake_docker(sys.argv[2:]))
    unittest.main()
