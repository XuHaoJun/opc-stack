#!/usr/bin/env python3
"""Provision a manifest-pinned revision in a trusted local linked worktree."""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import time


STORE = Path("/opt/opc-assets")
MANIFEST = ".worktree-assets.json"
STATE = ".worktree-assets-state"
BINDING = ".opc-assets-binding.json"
ASSETS = "assets"
LOCK = "lock"
STAGING = "staging"
LOCK_TIMEOUT = 30
HEX = re.compile(r"[0-9a-f]{64}")
STORE_NAME = re.compile(r"[a-z0-9][a-z0-9._-]*")
TARGET = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
# Non-dot candidates from the pinned Paperclip workspace compactor.
COMPACTION_TARGETS = {"node_modules", "dist", "build", "coverage", "storybook-static", "target"}
GIT_REPO_ENV = {
    "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX",
    "GIT_INTERNAL_SUPER_PREFIX", "GIT_IMPLICIT_WORK_TREE", "GIT_LITERAL_PATHSPECS",
    "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS",
    "GIT_NAMESPACE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_QUARANTINE_PATH",
}


class Outcome(Exception):
    def __init__(self, status, code, detail):
        super().__init__(detail)
        self.status = status
        self.code = code


def invalid(detail):
    raise Outcome("invalid", 2, detail)


def conflict(detail):
    raise Outcome("conflict", 2, detail)


def io_error(detail):
    raise Outcome("io-error", 3, detail)


def metadata(path):
    try:
        return path.lstat()
    except FileNotFoundError:
        return None


def is_type(path, predicate):
    info = metadata(path)
    return info is not None and predicate(info.st_mode)


def read_regular(path):
    # O_NONBLOCK prevents a replacement FIFO from hanging the caller.
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError(f"not a regular file: {path}")
        return stream.read()


def git(cwd, env, *args, input=None):
    return subprocess.run(["git", *args], cwd=cwd, env=env, input=input,
                          capture_output=True, check=False, timeout=30)


def git_path(cwd, env, flag):
    result = git(cwd, env, "rev-parse", "--path-format=absolute", flag)
    return Path(os.fsdecode(result.stdout.removesuffix(b"\n"))) if result.returncode == 0 else None


def linked_worktree(cwd, env):
    pointer = cwd / ".git"
    if not is_type(pointer, stat.S_ISREG) or git_path(cwd, env, "--show-toplevel") != cwd:
        return False
    git_dir = git_path(cwd, env, "--git-dir")
    common_dir = git_path(cwd, env, "--git-common-dir")
    if git_dir is None or common_dir is None or git_dir == common_dir:
        return False
    if git_dir.parent != common_dir / "worktrees" or not is_type(git_dir, stat.S_ISDIR):
        return False
    try:
        backlink = Path(os.fsdecode(read_regular(git_dir / "gitdir").removesuffix(b"\n")))
        common = Path(os.fsdecode(read_regular(git_dir / "commondir").removesuffix(b"\n")))
        return (git_dir / backlink).resolve(strict=True) == pointer and (git_dir / common).resolve(strict=True) == common_dir
    except (FileNotFoundError, ValueError):
        return False


def verify_git_contract(cwd, env):
    result = git(cwd, env, "ls-files", "--stage", "-z", "--", ASSETS, STATE, ".gitignore")
    if result.returncode:
        io_error(f"cannot read Git index: {os.fsdecode(result.stderr).strip()}")
    rows = result.stdout.rstrip(b"\0").split(b"\0") if result.stdout else []
    ignore_rows = []
    for row in rows:
        info, path = row.split(b"\t", 1)
        if path != b".gitignore":
            conflict(f"Git index occupies {os.fsdecode(path)!r}")
        ignore_rows.append(info.split())
    if (len(ignore_rows) != 1 or ignore_rows[0][0] not in (b"100644", b"100755")
            or ignore_rows[0][-1] != b"0" or not is_type(cwd / ".gitignore", stat.S_ISREG)):
        invalid("root .gitignore must be a tracked regular file")

    # The slash makes Git test directory-only rules even before publication.
    paths = [b"assets/", b".worktree-assets-state/"]
    result = git(cwd, env, "check-ignore", "--no-index", "--verbose", "--non-matching", "-z",
                 "--stdin", input=b"\0".join(paths) + b"\0")
    if result.returncode not in (0, 1):
        io_error(f"cannot check Git ignore rules: {os.fsdecode(result.stderr).strip()}")
    fields = result.stdout.split(b"\0")[:-1]
    for offset, path in enumerate(paths):
        row = fields[offset * 4:offset * 4 + 4]
        if len(row) != 4 or row[0] != b".gitignore" or not row[2] or row[2].startswith(b"!") or row[3] != path:
            invalid(f"{os.fsdecode(path)} must be ignored as a directory by tracked root .gitignore")


def unique_dict(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate field {key!r}")
        result[key] = value
    return result


def decode_json(data):
    return json.loads(data.decode("utf-8"), object_pairs_hook=unique_dict)


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def matches(value, pattern):
    return isinstance(value, str) and pattern.fullmatch(value) is not None


def source_parts(path):
    if not isinstance(path, str):
        raise ValueError("expected a relative source path")
    path.encode("utf-8")  # Reject escaped lone surrogates as well as invalid input bytes.
    parts = path.split("/")
    if any(part in ("", ".", "..") or part.lower() == ".git" or "\0" in part for part in parts):
        raise ValueError(f"unsafe source path {path!r}")
    return parts


def manifest(path):
    if not is_type(path, stat.S_ISREG):
        raise ValueError("not a regular file")
    value = decode_json(read_regular(path))
    if not isinstance(value, dict) or value.keys() != {"version", "store", "revision", "entries"}:
        raise ValueError("expected version, store, revision and entries")
    revision = value["revision"]
    if (type(value["version"]) is not int or value["version"] != 1
            or not matches(value["store"], STORE_NAME) or not isinstance(revision, str)
            or not revision.startswith("sha256:") or not matches(revision[7:], HEX)):
        raise ValueError("expected version 1, a lowercase store name and a sha256 revision")
    entries = value["entries"]
    if not isinstance(entries, list) or not entries:
        raise ValueError("expected nonempty entries")
    seen = set()
    for entry in entries:
        if not isinstance(entry, dict) or entry.keys() != {"target", "source", "mode"}:
            raise ValueError("each entry needs target, source and mode")
        target, mode = entry["target"], entry["mode"]
        if (not matches(target, TARGET) or target in seen or mode not in ("link", "clone")
                or (mode == "clone" and target in COMPACTION_TARGETS)):
            raise ValueError(f"invalid or duplicate target or mode: {target!r}, {mode!r}")
        source_parts(entry["source"])
        seen.add(target)
    entries.sort(key=lambda entry: entry["target"])
    return value


def confirm_readonly_mount(root):
    # st_dev may be shared by a Btrfs bind mount and its parent. The open
    # directory's mount ID identifies the visible mount even if mounts stack.
    try:
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            with open(f"/proc/self/fdinfo/{fd}", "rb") as info:
                mount_id = next((line.split()[1] for line in info if line.startswith(b"mnt_id:")), None)
            with open("/proc/self/mountinfo", "rb") as mounts:
                for line in mounts:
                    fields = line.split(b" ", 6)
                    if fields[0] == mount_id and fields[4] == os.fsencode(root) and b"ro" in fields[5].split(b","):
                        return
        finally:
            os.close(fd)
    except OSError as exc:
        io_error(f"{root} must be mounted read-only: {exc}")
    io_error(f"{root} must be an exact read-only mount")


def inventory(revision, digest):
    path = revision / "inventory.json"
    if not is_type(path, stat.S_ISREG):
        invalid(f"published revision lacks regular inventory: {path}")
    data = read_regular(path)
    if hashlib.sha256(data).hexdigest() != digest:
        invalid(f"published inventory digest mismatch: {path}")
    try:
        rows = decode_json(data)
        if not isinstance(rows, list) or not rows or data != canonical_json(rows):
            raise ValueError("expected a nonempty canonical inventory array")
        kinds = {}
        previous = b""
        for row in rows:
            if not isinstance(row, list) or not ((len(row) == 2 and row[0] == "d") or
                                               (len(row) == 3 and row[0] == "f" and matches(row[2], HEX))):
                raise ValueError("invalid inventory row")
            kind, name = row[:2]
            segments = source_parts(name)
            key = name.encode("utf-8")
            if key <= previous or (len(segments) > 1 and kinds.get(name.rsplit("/", 1)[0]) != "d"):
                raise ValueError("unordered inventory or missing parent directory")
            kinds[name] = kind
            previous = key
        return kinds
    except (ValueError, RecursionError) as exc:
        invalid(f"invalid published inventory {path}: {exc}")


def verify_directory_source(directory, source, kinds):
    prefix = source + "/"
    expected = {name: kind for name, kind in kinds.items() if name.startswith(prefix)}
    pending = [(directory, prefix)]
    while pending:
        current, parent = pending.pop()
        with os.scandir(current) as entries:
            for entry in entries:
                name = parent + entry.name
                kind = expected.pop(name, None)
                info = entry.stat(follow_symlinks=False)
                if kind == "d" and stat.S_ISDIR(info.st_mode):
                    pending.append((Path(entry.path), name + "/"))
                elif not (kind == "f" and stat.S_ISREG(info.st_mode) and info.st_nlink == 1):
                    invalid(f"published source does not match its inventory: {entry.path}")
    if expected:
        invalid(f"published source is missing inventory path: {next(iter(expected))!r}")


def revision_sources(root, pin, has_binding):
    if root == STORE:
        confirm_readonly_mount(root)
    elif not is_type(root, stat.S_ISDIR):
        io_error(f"store is not a directory: {root}")
    digest = pin["revision"][7:]
    revision = root
    for segment in (pin["store"], "revisions", digest):
        revision /= segment
        info = metadata(revision)
        if info is None:
            detail = f"{pin['store']} {pin['revision']}"
            if has_binding:
                conflict(f"bound revision disappeared: {detail}")
            raise Outcome("missing-revision", 1, detail)
        if not stat.S_ISDIR(info.st_mode):
            invalid(f"store path is not a real directory: {revision}")
    kinds = inventory(revision, digest)
    payload = revision / "payload"
    if not is_type(payload, stat.S_ISDIR):
        invalid(f"published revision lacks real payload directory: {payload}")
    sources = {}
    for entry in pin["entries"]:
        name = entry["source"]
        kind = kinds.get(name)
        if kind is None or (entry["mode"] == "clone" and kind != "d"):
            invalid(f"invalid {entry['mode']} source in published inventory: {name!r}")
        parts = name.split("/")
        path = payload
        for part in parts[:-1]:
            path /= part
            if not is_type(path, stat.S_ISDIR):
                invalid(f"published source parent is not a real directory: {path}")
        path /= parts[-1]
        info = metadata(path)
        if info is None or not (stat.S_ISDIR(info.st_mode) if kind == "d" else
                                stat.S_ISREG(info.st_mode) and info.st_nlink == 1):
            invalid(f"published source does not match its inventory: {path}")
        if kind == "d":
            verify_directory_source(path, name, kinds)
        sources[entry["target"]] = path
    return sources


def owned(info):
    return info.st_uid == os.geteuid() and not (info.st_mode & 0o022)


def check_state(state):
    info = metadata(state)
    if info is None:
        return
    if not stat.S_ISDIR(info.st_mode) or not owned(info):
        conflict(f"state is not a real directory owned by the runtime user: {state}")
    if set(os.listdir(state)) - {LOCK, STAGING}:
        conflict(f"unrecognized files in state directory: {state}")
    stage = metadata(state / STAGING)
    lock = metadata(state / LOCK)
    if lock is not None and (not stat.S_ISREG(lock.st_mode) or lock.st_nlink != 1 or not owned(lock)):
        conflict(f"invalid lock file: {state / LOCK}")
    if stage is not None and (lock is None or not stat.S_ISDIR(stage.st_mode) or not owned(stage)
                              or stat.S_IMODE(stage.st_mode) & 0o077):
        conflict(f"invalid staging directory: {state / STAGING}")


def evaluate(cwd, root, env):
    manifest_path = cwd / MANIFEST
    output = cwd / ASSETS
    state = cwd / STATE
    if metadata(manifest_path) is None and metadata(state) is None:
        # An unconfigured project may legitimately own assets/. A binding at
        # the reserved pathname still exposes a previously configured project.
        if not is_type(output, stat.S_ISDIR) or metadata(output / BINDING) is None:
            raise Outcome("not-configured", 0, "no worktree assets manifest")
    if env.get("WORKTREE_ASSETS_ENABLED") == "false":
        raise Outcome("disabled", 0, "WORKTREE_ASSETS_ENABLED=false")
    for option in ("PAPERCLIP_GIT_CACHE_EXPIRATION_ENABLED", "PAPERCLIP_GIT_RESTORE_POINTS_ENABLED"):
        if env.get(option) == "true":
            invalid(f"{option}=true is incompatible with worktree assets")
    if metadata(manifest_path) is None:
        conflict("manifest removed from a worktree with existing asset state")
    try:
        pin = manifest(manifest_path)
    except (ValueError, RecursionError) as exc:
        invalid(f"invalid {MANIFEST}: {exc}")
    output_info = metadata(output)
    if output_info is not None and not stat.S_ISDIR(output_info.st_mode):
        conflict(f"{ASSETS}/ is not a real directory")
    check_state(state)
    verify_git_contract(cwd, env)
    bound = output_info is not None
    if bound:
        try:
            current = manifest(output / BINDING)
        except (ValueError, RecursionError) as exc:
            conflict(f"existing {ASSETS}/ lacks a valid binding: {exc}")
        if current != pin:
            conflict("manifest differs from existing binding; use a new execution worktree")
    sources = revision_sources(root, pin, bound)
    if bound:
        for entry in pin["entries"]:
            target = entry["target"]
            path = output / target
            if entry["mode"] == "link":
                if not is_type(path, stat.S_ISLNK) or os.readlink(path) != str(sources[target]):
                    conflict(f"bound link was removed or changed: {path}")
            elif not is_type(path, stat.S_ISDIR):
                conflict(f"bound clone is not a real directory: {path}")
        raise Outcome("ready", 0, f"{pin['store']} {pin['revision']}")
    return pin, sources


def take_lock(state):
    state.mkdir(mode=0o700, exist_ok=True)
    check_state(state)
    path = state / LOCK
    try:
        fd = os.open(path, os.O_CREAT | os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.EISDIR):
            conflict(f"invalid lock file: {path}")
        raise
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not owned(info):
            conflict(f"invalid lock file: {path}")
        deadline = time.monotonic() + LOCK_TIMEOUT
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    io_error(f"timed out waiting for {path}")
                time.sleep(min(remaining, 0.1))
        if not os.path.samestat(info, path.lstat()):
            conflict(f"lock file was replaced: {path}")
        return fd
    except BaseException:
        os.close(fd)
        raise


def provision(cwd, root, env):
    state = cwd / STATE
    output = cwd / ASSETS
    stage = state / STAGING
    lock = take_lock(state)
    try:
        try:
            pin, sources = evaluate(cwd, root, env)
        except Outcome as outcome:
            if outcome.status == "ready" and metadata(stage) is not None:
                shutil.rmtree(stage)
            raise
        if metadata(stage) is not None:
            shutil.rmtree(stage)
        stage.mkdir(mode=0o700)
        reflink = "auto" if env.get("WORKTREE_ASSETS_ALLOW_FULL_COPY") == "1" else "always"
        try:
            for entry in pin["entries"]:
                target = entry["target"]
                destination = stage / target
                if entry["mode"] == "link":
                    destination.symlink_to(sources[target])
                else:
                    # A surviving child retains the same open file description
                    # and flock even when the Python parent is killed.
                    subprocess.run(["/usr/bin/cp", "-R", "--no-dereference", f"--reflink={reflink}", "--",
                                    sources[target], destination], check=True, env=env, pass_fds=(lock,), umask=0o022)
            with (stage / BINDING).open("xb") as binding:
                binding.write(canonical_json(pin))
            subprocess.run(["/usr/bin/mv", "-T", "--no-copy", "--update=none-fail", "--", stage, output],
                           check=True, env=env, pass_fds=(lock,))
        except (OSError, subprocess.CalledProcessError) as exc:
            shutil.rmtree(stage)
            if metadata(output) is not None:
                conflict(f"destination appeared during provision: {output}")
            if isinstance(exc, subprocess.CalledProcessError) and exc.cmd[0] == "/usr/bin/cp" and reflink == "always":
                io_error("reflink clone failed; enable full-copy fallback only after assessing capacity")
            raise
        raise Outcome("ready", 0, f"{pin['store']} {pin['revision']}")
    finally:
        # Do not explicitly unlock: an inherited descriptor may still be live.
        os.close(lock)


def run(command, *, cwd, store_root, env):
    """Return the command exit code; nonproduction storage is test injection only."""
    if command not in ("init", "status"):
        raise ValueError(f"unknown command {command!r}")
    try:
        cwd = Path(cwd).resolve(strict=True)
        root = Path(store_root).absolute()
        git_env = {key: value for key, value in env.items() if key not in GIT_REPO_ENV}
        if not linked_worktree(cwd, git_env):
            raise Outcome("not-worktree", 0, "not at the root of a linked Git worktree")
        pin, _ = evaluate(cwd, root, git_env)
        if command == "status":
            raise Outcome("not-provisioned", 1, f"{pin['store']} {pin['revision']}")
        provision(cwd, root, git_env)
    except Outcome as outcome:
        print(f"{outcome.status}: {outcome}")
        return 1 if command == "status" and outcome.status == "disabled" else outcome.code
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"io-error: {exc}")
        return 3


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("init", "status"))
    args = parser.parse_args()
    return run(args.command, cwd=Path.cwd(), store_root=STORE, env=os.environ)


if __name__ == "__main__":
    raise SystemExit(main())
