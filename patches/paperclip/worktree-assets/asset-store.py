#!/usr/bin/env python3
"""Stream tar from the operator's host and manage immutable volume revisions."""

import argparse
from contextlib import ExitStack, contextmanager
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import sys
import tarfile
import uuid


STORE_ROOT = Path('/opt/opc-assets')
STORE_NAME = re.compile(r'[a-z0-9][a-z0-9._-]*')
HEX_DIGEST = re.compile(r'[0-9a-f]{64}')
TOKEN = re.compile(r'[0-9a-f]{32}')
CHUNK = 1024 * 1024
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class StoreError(ValueError):
    pass


def store_name(value):
    if not STORE_NAME.fullmatch(value):
        raise StoreError(f'invalid store name: {value!r} (use lowercase ASCII letters, digits, ., _, -)')
    return value


def digest_hex(revision):
    if not revision.startswith('sha256:') or not HEX_DIGEST.fullmatch(revision[7:]):
        raise StoreError('revision must be sha256: followed by exactly 64 lowercase hex digits')
    return revision[7:]


def checked_token(token):
    if not TOKEN.fullmatch(token):
        raise StoreError('invalid staging token')
    return token


def path_parts(path):
    parts = path.split('/')
    if '\0' in path or any(part in ('', '.', '..') or part.lower() == '.git' for part in parts):
        raise StoreError(f'unsafe asset path: {path!r}')
    try:
        path.encode('utf-8')
    except UnicodeEncodeError as exc:
        raise StoreError(f'asset path is not valid UTF-8: {path!r}') from exc
    return parts


def identity(info):
    return info.st_dev, info.st_ino


def pack(host_dir, entries, stream):
    """Create an archive of explicit entries, never following local aliases."""
    for entry in entries:
        if len(path_parts(entry)) != 1:
            raise StoreError(f'entry must be a top-level name: {entry!r}')
    if not entries or len(set(entries)) != len(entries):
        raise StoreError('select distinct top-level asset entries')

    def emit(tar, parent_fd, name, path):
        path_parts(path)
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        item = tarfile.TarInfo(path)
        if stat.S_ISDIR(before.st_mode):
            fd = os.open(name, DIR_FLAGS, dir_fd=parent_fd)
            try:
                if identity(before) != identity(os.fstat(fd)):
                    raise StoreError(f'source changed during import: {path!r}')
                item.type = tarfile.DIRTYPE
                tar.addfile(item)
                with os.scandir(fd) as children:
                    for child in children:
                        emit(tar, fd, child.name, f'{path}/{child.name}')
                after = os.fstat(fd)
            finally:
                os.close(fd)
        elif stat.S_ISREG(before.st_mode) and before.st_nlink == 1:
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            with os.fdopen(os.open(name, flags, dir_fd=parent_fd), 'rb') as source:
                info = os.fstat(source.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                        or identity(before) != identity(info)):
                    raise StoreError(f'source changed during import: {path!r}')
                item.size = info.st_size
                tar.addfile(item, source)
                after = os.fstat(source.fileno())
        else:
            raise StoreError(f'not a regular file or real directory (links are forbidden): {path!r}')
        if (before.st_mtime_ns, before.st_ctime_ns) != (after.st_mtime_ns, after.st_ctime_ns):
            raise StoreError(f'source changed during import: {path!r}')

    # Path removes trailing slash, which would otherwise bypass O_NOFOLLOW.
    fd = os.open(Path(host_dir), DIR_FLAGS)
    try:
        with tarfile.open(fileobj=stream, mode='w|', format=tarfile.PAX_FORMAT, bufsize=CHUNK,
                          copybufsize=CHUNK, encoding='utf-8', errors='strict') as tar:
            for entry in entries:
                emit(tar, fd, entry, entry)
    finally:
        os.close(fd)


def resolve_compose(stream):
    config = json.load(stream)
    try:
        values = (config['name'], config['services']['paperclip']['image'],
                  config['volumes']['opc-assets']['name'])
    except (KeyError, TypeError) as exc:
        raise StoreError('Compose must resolve a project, Paperclip service image, and opc-assets volume') from exc
    patterns = (r'[a-z0-9][a-z0-9_-]*', r'[A-Za-z0-9][A-Za-z0-9_./:@-]*',
                r'[A-Za-z0-9][A-Za-z0-9_.-]*')
    if not all(isinstance(value, str) and re.fullmatch(pattern, value)
               for pattern, value in zip(patterns, values)):
        raise StoreError('Compose resolved an invalid project, Paperclip image, or opc-assets volume name')
    return '\t'.join(values)


def directory(path, *, optional=False):
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        if optional:
            return None
        raise StoreError(f'required directory does not exist: {path}') from exc
    if not stat.S_ISDIR(info.st_mode):
        raise StoreError(f'expected a real directory: {path}')
    return info


def regular_file(path):
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise StoreError(f'required file does not exist: {path}') from exc
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise StoreError(f'expected a regular file without aliases: {path}')
    return info


@contextmanager
def locked_directory(path, *, shared=False):
    fd = os.open(path, DIR_FLAGS)
    try:
        fcntl.flock(fd, fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def new_directory(path, mode):
    path.mkdir(mode=mode)
    path.chmod(mode)


def initialize(root, store, uid, gid):
    """Bootstrap only known directories as root; all content IO is unprivileged."""
    managed = root / store_name(store)
    with locked_directory(root):
        for path, mode in ((root / '.staging', 0o700), (root / '.retired', 0o700),
                           (managed, 0o755), (managed / 'revisions', 0o755)):
            info = directory(path, optional=True)
            if info is None:
                new_directory(path, mode)
                info = directory(path)
            if (info.st_uid, info.st_gid) != (uid, gid):
                if info.st_uid != 0:
                    raise StoreError(f'{path} is not owned by the Paperclip runtime user')
                os.chown(path, uid, gid, follow_symlinks=False)
            if stat.S_IMODE(info.st_mode) != mode:
                path.chmod(mode)


def revisions_directory(root, store, *, optional=False):
    managed = root / store_name(store)
    if directory(managed, optional=optional) is not None:
        path = managed / 'revisions'
        if directory(path, optional=optional) is not None:
            return path
    return None


class StrictTarInfo(tarfile.TarInfo):
    @classmethod
    def fromtarfile(cls, archive):
        # Streaming TarFile.next can interpret malformed trailing headers as EOF.
        try:
            return super().fromtarfile(archive)
        except tarfile.EOFHeaderError:
            raise
        except tarfile.HeaderError as exc:
            raise StoreError(f'invalid tar header: {exc}') from exc


def extract(stream, payload):
    rows = {}
    with tarfile.open(fileobj=stream, mode='r|', tarinfo=StrictTarInfo,
                      bufsize=CHUNK, encoding='utf-8') as tar:
        for member in iter(tar.next, None):
            parts = path_parts(member.name)
            path = member.name
            if path in rows:
                raise StoreError(f'duplicate tar member: {path!r}')
            if len(parts) > 1 and rows.get(path.rsplit('/', 1)[0], [''])[0] != 'd':
                raise StoreError(f'tar member has no preceding real parent directory: {path!r}')
            if member.sparse is not None or member.size < 0:
                raise StoreError(f'sparse or invalid-size tar member: {path!r}')
            target = payload.joinpath(*parts)
            if member.type == tarfile.DIRTYPE and member.size == 0:
                new_directory(target, 0o755)
                rows[path] = ['d', path]
            elif member.type in (tarfile.REGTYPE, tarfile.AREGTYPE):
                sha = hashlib.sha256()
                with tar.extractfile(member) as source, target.open('xb') as output:
                    for chunk in iter(lambda: source.read(CHUNK), b''):
                        output.write(chunk)
                        sha.update(chunk)
                    os.fchmod(output.fileno(), 0o644)
                rows[path] = ['f', path, sha.hexdigest()]
            else:
                raise StoreError(f'tar member is not a regular file or real directory: {path!r}')
            # Older Python versions cache TarInfo objects even in streaming mode.
            tar.members.clear()
        # The parser consumed one zero block. Require the second and drain only
        # zero padding to EOF, so concatenated archives cannot hide later members.
        padding = 0
        for chunk in iter(lambda: tar.fileobj.read(CHUNK), b''):
            if chunk.strip(b'\0'):
                raise StoreError('nonzero data after tar end-of-archive marker')
            padding += len(chunk)
        if tar.fileobj.tell() != tar.offset + tarfile.BLOCKSIZE + padding:
            raise StoreError('missing tar end-of-archive marker')
        if padding < tarfile.BLOCKSIZE or padding % tarfile.BLOCKSIZE:
            raise StoreError('incomplete tar end-of-archive marker or padding')
    if not rows:
        raise StoreError('tar archive has no selected entries')
    return json.dumps(sorted(rows.values(), key=lambda row: row[1].encode('utf-8')),
                      ensure_ascii=False, separators=(',', ':')).encode('utf-8')


def stage(root, store, token, stream):
    path = root / '.staging' / checked_token(token)
    with ExitStack() as locks:
        with locked_directory(root):
            revisions_directory(root, store)
            directory(path.parent)
            new_directory(path, 0o700)
            locks.enter_context(locked_directory(path))
        try:
            revision_dir = path / 'revision'
            new_directory(revision_dir, 0o755)
            payload = revision_dir / 'payload'
            new_directory(payload, 0o755)
            inventory = extract(stream, payload)
            with (revision_dir / 'inventory.json').open('xb') as output:
                output.write(inventory)
                os.fchmod(output.fileno(), 0o644)
            revision = 'sha256:' + hashlib.sha256(inventory).hexdigest()
            # The marker is private and written last, outside the directory to publish.
            (path / 'complete').write_text(f'{store} {revision}\n', encoding='ascii')
            return revision
        except BaseException:
            shutil.rmtree(path)
            raise


def cleanup(root, token):
    path = root / '.staging' / checked_token(token)
    with locked_directory(root):
        if directory(path.parent, optional=True) is None:
            return
        try:
            with locked_directory(path):
                # A failing stage may have removed its directory while we waited.
                if directory(path, optional=True) is not None:
                    shutil.rmtree(path)
        except FileNotFoundError:
            if directory(path, optional=True) is not None:
                raise


def rename_no_replace(source, destination):
    # Linux renameat2 on the volume: no replacement, and no cross-device copy.
    rename = getattr(ctypes.CDLL(None, use_errno=True), 'renameat2', None)
    if rename is None:
        raise StoreError('atomic no-replace rename requires Linux renameat2')
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    at_fdcwd, rename_noreplace = -100, 1
    if rename(at_fdcwd, os.fsencode(source), at_fdcwd, os.fsencode(destination), rename_noreplace):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), source, None, destination)


def revision_inventory(path, hex_digest):
    directory(path)
    directory(path / 'payload')
    inventory_path = path / 'inventory.json'
    regular_file(inventory_path)
    inventory = inventory_path.read_bytes()
    if hashlib.sha256(inventory).hexdigest() != hex_digest:
        raise StoreError(f'inventory does not match revision digest: {path}')
    return inventory


def verify_published_payload(payload, inventory):
    expected = {row[1]: row for row in json.loads(inventory)}
    pending = [(payload, '')]
    while pending:
        directory_path, prefix = pending.pop()
        with os.scandir(directory_path) as entries:
            for entry in entries:
                name = prefix + entry.name
                row = expected.pop(name, None)
                info = entry.stat(follow_symlinks=False)
                if row and row[0] == 'd' and stat.S_ISDIR(info.st_mode):
                    pending.append((Path(entry.path), name + '/'))
                    continue
                if not (row and row[0] == 'f' and stat.S_ISREG(info.st_mode) and info.st_nlink == 1):
                    raise StoreError(f'published payload does not match inventory: {name!r}')
                with open(entry.path, 'rb') as source:
                    if hashlib.file_digest(source, 'sha256').hexdigest() != row[2]:
                        raise StoreError(f'published payload checksum mismatch: {name!r}')
    if expected:
        raise StoreError(f'published payload is missing inventory path: {next(iter(expected))!r}')


def publish(root, store, token, revision):
    path = root / '.staging' / checked_token(token)
    hex_digest = digest_hex(revision)
    with locked_directory(root):
        revisions = revisions_directory(root, store)
        directory(path.parent)
        directory(path)
        with locked_directory(path):
            marker = path / 'complete'
            regular_file(marker)
            if marker.read_text(encoding='ascii') != f'{store} {revision}\n':
                raise StoreError('staged store or revision does not match publish request')
            prepared = path / 'revision'
            inventory = revision_inventory(prepared, hex_digest)
            destination = revisions / hex_digest
            try:
                rename_no_replace(prepared, destination)
            except FileExistsError:
                if revision_inventory(destination, hex_digest) != inventory:
                    raise StoreError(f'published inventory differs from staging: {destination}')
                verify_published_payload(destination / 'payload', inventory)
                result = 'existing'
            else:
                result = 'published'
            try:
                shutil.rmtree(path)
            except OSError as exc:
                raise StoreError(f'{revision} is published, but cannot remove staging {path}: {exc}') from exc
            return result


def logical_bytes(path):
    total = 0
    pending = [path]
    while pending:
        with os.scandir(pending.pop()) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    pending.append(entry.path)
                elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                    total += info.st_size
                else:
                    raise StoreError(f'invalid object in published payload: {entry.path!r}')
    return total


def listing(root, store, output):
    with locked_directory(root, shared=True):
        print('store\trevision\tlogical_bytes', file=output)
        stores = (store,) if store is not None else sorted(
            path.name for path in root.iterdir() if STORE_NAME.fullmatch(path.name))
        for selected in stores:
            revisions = revisions_directory(root, selected, optional=True)
            if revisions is not None:
                for path in sorted(revisions.iterdir()):
                    if HEX_DIGEST.fullmatch(path.name):
                        revision_inventory(path, path.name)
                        size = logical_bytes(path / 'payload')
                        print(f'{selected}\tsha256:{path.name}\t{size}', file=output)


def retire(root, store, revision, project, volume, terminal, output):
    hex_digest = digest_hex(revision)
    store_name(store)
    if not terminal.isatty() or not output.isatty():
        raise StoreError('retire requires an interactive terminal; nothing was removed')
    with locked_directory(root, shared=True):
        path = revisions_directory(root, store) / hex_digest
        before = directory(path)
        revision_inventory(path, hex_digest)
        size = logical_bytes(path / 'payload')
    print(f'Deployment: Compose project {project}, volume {volume}\n'
          f'Retire: {store} {revision} ({size} logical bytes)\n'
          'Use a maintenance window only: verify the source backup, check that no supported refs or '
          'recoverable workspaces need this revision, and stop all consumers and imports.\n'
          'Enter the full digest to confirm: ', end='', file=output, flush=True)
    if terminal.readline().removesuffix('\n') != revision:
        raise StoreError('confirmation did not match; nothing was retired')
    with locked_directory(root):
        if identity(directory(path)) != identity(before):
            raise StoreError('published revision changed after the preview; rerun retire')
        revision_inventory(path, hex_digest)
        retired = root / '.retired'
        directory(retired)
        quarantine = retired / f'{hex_digest}-{uuid.uuid4().hex}'
        rename_no_replace(path, quarantine)
    print(f'Removed from the published namespace; deleting {quarantine}.', file=output, flush=True)
    try:
        shutil.rmtree(quarantine)
    except OSError as exc:
        raise StoreError(f'{revision} is no longer published; remove remaining data at {quarantine}: {exc}') from exc
    print(f'Retired {store} {revision}.', file=output)


def allocate_args(argv):
    parser = argparse.ArgumentParser(prog='asset-store')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('resolve-compose')
    sub.add_parser('token')
    pack_args = sub.add_parser('pack')
    pack_args.add_argument('host_dir')
    pack_args.add_argument('entries', nargs='+')
    sub.add_parser('init').add_argument('store')
    stage_args = sub.add_parser('stage')
    stage_args.add_argument('store')
    stage_args.add_argument('token')
    publish_args = sub.add_parser('publish')
    publish_args.add_argument('store')
    publish_args.add_argument('token')
    publish_args.add_argument('revision')
    sub.add_parser('cleanup').add_argument('token')
    sub.add_parser('list').add_argument('store', nargs='?')
    retire_args = sub.add_parser('retire')
    retire_args.add_argument('store')
    retire_args.add_argument('revision')
    retire_args.add_argument('project')
    retire_args.add_argument('volume')
    return parser.parse_args(argv)


def main(argv=None, *, root=STORE_ROOT, runtime_identity=None):
    args = allocate_args(argv)
    try:
        if args.command == 'resolve-compose':
            print(resolve_compose(sys.stdin))
        elif args.command == 'token':
            print(uuid.uuid4().hex)
        elif args.command == 'pack':
            pack(args.host_dir, args.entries, sys.stdout.buffer)
        elif args.command == 'init':
            if runtime_identity is None:
                user = pwd.getpwnam('node')
                runtime_identity = user.pw_uid, user.pw_gid
            initialize(root, args.store, *runtime_identity)
        elif args.command == 'stage':
            revision = stage(root, args.store, args.token, sys.stdin.buffer)
            print(f'{args.token} {revision}')
        elif args.command == 'cleanup':
            cleanup(root, args.token)
        elif args.command == 'publish':
            outcome = publish(root, args.store, args.token, args.revision)
            message = 'already exists' if outcome == 'existing' else 'published'
            print(f'opc-assets: {args.store} {args.revision} {message}', file=sys.stderr)
        elif args.command == 'list':
            listing(root, args.store, sys.stdout)
        elif args.command == 'retire':
            retire(root, args.store, args.revision, args.project, args.volume, sys.stdin, sys.stdout)
    except (OSError, ValueError, KeyError, tarfile.TarError) as exc:
        print(f'opc-assets: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
