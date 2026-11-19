#!/usr/bin/env python3
import concurrent.futures
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


CLI = Path(__file__).resolve().parents[1] / "patches/paperclip/worktree-assets/worktree-assets.py"
spec = importlib.util.spec_from_file_location("worktree_assets", CLI)
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class WorktreeTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.main = self.root / "main"
        self.cwd = self.root / "linked"
        self.store = self.root / "volume"
        self.store.mkdir()
        self.main.mkdir()
        self.env = {"WORKTREE_ASSETS_ALLOW_FULL_COPY": "1", "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_CONFIG_GLOBAL": "/dev/null", "PATH": os.environ["PATH"]}
        self.git("init", "-q", cwd=self.main)
        self.git("config", "user.name", "Fixture", cwd=self.main)
        self.git("config", "user.email", "fixture@example.invalid", cwd=self.main)
        self.manifest = {"version": 1, "store": "demo", "revision": "sha256:" + "0" * 64,
                         "entries": [{"source": "Data", "target": "Data", "mode": "link"},
                                     {"source": "game", "target": "game", "mode": "clone"}]}
        (self.main / ".gitignore").write_text("/assets/\n/.worktree-assets-state/\n")
        self.configure(self.main)
        self.git("add", ".", cwd=self.main)
        self.git("commit", "-qm", "fixture", cwd=self.main)
        self.git("worktree", "add", "-q", "--detach", str(self.cwd), cwd=self.main)
        self.output = self.cwd / "assets"
        self.state = self.cwd / ".worktree-assets-state"

    def configure(self, cwd=None):
        (cwd or self.cwd).joinpath(".worktree-assets.json").write_text(json.dumps(self.manifest))

    def git(self, *args, cwd=None):
        return subprocess.check_output(["git", *args], cwd=cwd or self.cwd, env=self.env)

    def publish(self, value="sample"):
        file_hash = hashlib.sha256(value.encode()).hexdigest()
        inventory = f'[["d","Data"],["d","game"],["f","game/example","{file_hash}"]]'.encode()
        digest = hashlib.sha256(inventory).hexdigest()
        revision = self.store / "demo/revisions" / digest
        (revision / "payload/Data").mkdir(parents=True)
        (revision / "payload/game").mkdir()
        (revision / "payload/game/example").write_text(value)
        (revision / "inventory.json").write_bytes(inventory)
        self.manifest["revision"] = f"sha256:{digest}"
        self.configure()
        return revision

    def invoke(self, command="init", cwd=None, **env):
        return assets.run(command, cwd=cwd or self.cwd, store_root=self.store, env=self.env | env)

    def test_missing_disabled_and_corrupt_revisions_write_nothing(self):
        self.assertEqual(self.invoke(WORKTREE_ASSETS_ENABLED="false"), 0)
        self.assertEqual(self.invoke("status", WORKTREE_ASSETS_ENABLED="false"), 1)
        self.assertEqual(self.invoke(), 1)
        revision = self.publish()
        (revision / "inventory.json").unlink()
        self.assertEqual(self.invoke(), 2)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.output.exists())

    def test_source_symlink_and_invalid_inventory_are_not_missing(self):
        revision = self.publish()
        path = revision / "payload/game"
        shutil.rmtree(path)
        path.symlink_to(revision / "payload/Data")
        self.assertEqual(self.invoke(), 2)
        path.unlink()
        path.mkdir()
        (revision / "inventory.json").write_text("[]")
        self.assertEqual(self.invoke(), 2)
        self.assertFalse(self.state.exists())

    def test_missing_file_inside_selected_directory_never_publishes_partial_assets(self):
        revision = self.publish()
        (revision / "payload/game/example").unlink()
        self.assertEqual(self.invoke("status"), 2)
        self.assertEqual(self.invoke(), 2)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.state.exists())

    def test_index_occupancy_precedes_provision_even_if_file_missing(self):
        self.publish()
        self.output.mkdir()
        file = self.output / "tracked"
        file.touch()
        self.git("add", "-f", "assets/tracked")
        file.unlink()
        self.output.rmdir()
        self.assertEqual(self.invoke(), 2)
        self.assertFalse(self.state.exists())

    def test_ignore_must_come_from_root_gitignore(self):
        self.publish()
        (self.cwd / ".gitignore").write_text("/assets/*\n")
        self.git("config", "core.excludesFile", str(self.root / "exclude"))
        (self.root / "exclude").write_text("/assets/\n/.worktree-assets-state/\n")
        self.assertEqual(self.invoke(), 2)
        (self.cwd / ".gitignore").write_text("/assets/*\n/.worktree-assets-state/\n")
        self.assertEqual(self.invoke(), 2)
        self.assertFalse(self.state.exists())

    def test_forged_linked_git_pointer_is_not_a_worktree(self):
        fake = self.root / "fake"
        fake.mkdir()
        (fake / ".git").write_bytes((self.cwd / ".git").read_bytes())
        self.configure(fake)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(self.invoke(cwd=fake), 0)
        self.assertIn("not-worktree", stdout.getvalue())
        self.assertEqual(sorted(p.name for p in fake.iterdir()), [".git", ".worktree-assets.json"])

    def test_namespace_collisions_are_never_claimed(self):
        self.publish()
        outsider = self.root / "outsider"
        outsider.mkdir()
        self.output.symlink_to(outsider)
        self.assertEqual(self.invoke(), 2)
        self.output.unlink()
        self.state.symlink_to(outsider)
        self.assertEqual(self.invoke(), 2)
        self.state.unlink()
        self.state.mkdir()
        (self.state / "lock").symlink_to(outsider / "lock")
        self.assertEqual(self.invoke(), 2)
        self.assertEqual(list(outsider.iterdir()), [])
        self.assertFalse(self.output.exists())

    def test_simultaneous_init_reuses_the_same_writable_private_clone(self):
        revision = self.publish()
        self.assertEqual(self.invoke("status"), 1)
        self.assertFalse(self.state.exists())
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(list(pool.map(lambda _: self.invoke(), range(2))), [0, 0])
        self.assertEqual((self.output / "Data").readlink(), revision / "payload/Data")
        self.assertFalse((self.output / "game").is_symlink())
        (self.output / "game/example").write_text("changed")
        self.manifest["entries"].reverse()
        self.configure()
        self.assertEqual(self.invoke(), 0)
        self.assertEqual((self.output / "game/example").read_text(), "changed")
        self.assertEqual((revision / "payload/game/example").read_text(), "sample")
        self.assertEqual(self.git("status", "--porcelain", "--untracked-files=all"), b" M .worktree-assets.json\n")
        self.publish("other revision")
        self.assertEqual(self.invoke(), 2)
        self.assertEqual((self.output / "Data").readlink(), revision / "payload/Data")

    def test_existing_binding_cannot_be_repaired_or_rebound(self):
        revision = self.publish()
        self.assertEqual(self.invoke(), 0)
        (self.output / "Data").unlink()
        self.assertEqual(self.invoke(), 2)
        self.assertFalse((self.output / "Data").exists())
        (self.output / "Data").symlink_to(revision / "payload/Data")
        shutil.rmtree(revision)
        self.assertEqual(self.invoke(), 2)
        (self.cwd / ".worktree-assets.json").unlink()
        self.assertEqual(self.invoke(), 2)

    def test_destination_created_at_rename_is_never_overwritten(self):
        self.publish()
        real_run = subprocess.run

        def race(args, **kwargs):
            if args[0] == "/usr/bin/mv":
                self.output.mkdir()
            return real_run(args, **kwargs)

        with patch.object(assets.subprocess, "run", side_effect=race):
            self.assertEqual(self.invoke(), 2)
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertEqual(sorted(p.name for p in self.state.iterdir()), ["lock"])
        self.assertEqual(self.invoke(), 2)

    def test_abandoned_staging_is_removed_only_during_init(self):
        self.publish()
        self.state.mkdir(mode=0o700)
        lock = self.state / "lock"
        lock.touch(mode=0o600)
        inode = lock.stat().st_ino
        stale = self.state / "staging"
        stale.mkdir(mode=0o700)
        human = self.root / "human"
        human.write_text("keep")
        (stale / "old-link").symlink_to(human)
        self.assertEqual(self.invoke("status"), 1)
        self.assertTrue(stale.exists())
        self.assertEqual(self.invoke(), 0)
        self.assertFalse(stale.exists())
        self.assertEqual(lock.stat().st_ino, inode)
        self.assertEqual(human.read_text(), "keep")

    def test_surviving_copy_child_keeps_lock_after_parent_unwinds(self):
        self.publish()
        children = []
        real_run = subprocess.run

        def interrupted_copy(args, **kwargs):
            if args[0] == "/usr/bin/cp":
                # Use a real blocking child to deterministically model an
                # interrupted parent while the copy still owns its descriptor.
                child = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read(1)"],
                                         stdin=subprocess.PIPE, pass_fds=kwargs["pass_fds"])
                children.append(child)
                raise KeyboardInterrupt
            return real_run(args, **kwargs)

        try:
            with patch.object(assets.subprocess, "run", side_effect=interrupted_copy):
                with self.assertRaises(KeyboardInterrupt):
                    self.invoke()
            stage = self.state / "staging"
            self.assertTrue(stage.is_dir())
            with patch.object(assets, "LOCK_TIMEOUT", 0):
                self.assertEqual(self.invoke(), 3)
            self.assertTrue(stage.is_dir())
            self.assertFalse(self.output.exists())
        finally:
            for child in children:
                child.communicate(timeout=5)
        self.assertEqual(self.invoke(), 0)
        self.assertFalse(stage.exists())


if __name__ == "__main__":
    unittest.main()
