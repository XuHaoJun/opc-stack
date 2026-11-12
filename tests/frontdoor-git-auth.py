#!/usr/bin/env python3
"""Real Git/gh across the frontdoor uid boundary; offline fixture credentials only."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


TOKEN = "fixture-frontdoor-token-not-a-secret"
ROTATED = "fixture-rotated-token-not-a-secret"


class FrontdoorGitAuth(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="frontdoor-git-auth-")
        self.addCleanup(self.scratch.cleanup)
        self.home = Path(self.scratch.name) / "home with spaces"
        self.home.mkdir(mode=0o700)
        os.chmod(self.scratch.name, 0o755)
        os.chown(self.home, 10000, 10000)
        self.source = Path("/creds")
        shutil.rmtree(self.source, ignore_errors=True)
        (self.source / "gh").mkdir(parents=True, mode=0o700)
        (self.source / "git").mkdir()
        (self.source / "git/config").write_text(
            '[user]\n name = Fixture\n email = fixture@example.invalid\n'
            '[credential "https://github.com"]\n helper =\n'
            ' helper = !gh auth git-credential\n'
        )
        self.login(TOKEN)
        self.env = {**os.environ, "HERMES_HOME": str(self.home)}
        for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR", "GIT_CONFIG_GLOBAL"):
            self.env.pop(name, None)

    def login(self, token):
        host = self.source / "gh/hosts.yml"
        host.write_text(
            f"github.com:\n    user: fixture\n    oauth_token: {token}\n"
            "    git_protocol: ssh\n"
        )
        (self.source / "gh/config.yml").write_text("git_protocol: ssh\n")
        for path in (self.source / "gh").iterdir():
            os.chown(path, 1000, 1000)
            path.chmod(0o600)
        os.chown(self.source / "gh", 1000, 1000)

    def seed(self):
        result = subprocess.run(
            ["sh", "-ec", ". /usr/local/bin/opc-gh-seed.sh; opc_gh_seed; env -0"],
            env=self.env, capture_output=True, check=True,
        )
        self.runtime_env = dict(
            item.split("=", 1) for item in result.stdout.decode().split("\0") if item
        )
        self.runtime_env.update(HOME=str(self.home), GIT_CONFIG_NOSYSTEM="1")

    def runtime(self, *args, input=None):
        return subprocess.run(
            ["setpriv", "--reuid=10000", "--regid=10000", "--groups=3000", *args],
            env=self.runtime_env, cwd=self.home, input=input,
            capture_output=True, text=True,
        )

    def test_agent_uid_can_use_gh_and_git_without_changing_source_permissions(self):
        self.seed()
        login = self.runtime("gh", "auth", "token", "--hostname", "github.com")
        self.assertEqual(login.returncode, 0, login.stderr)
        self.assertEqual(login.stdout.strip(), TOKEN)
        credential = self.runtime(
            "git", "credential", "fill", input="protocol=https\nhost=github.com\n\n"
        )
        self.assertEqual(credential.returncode, 0, credential.stderr)
        self.assertIn(f"password={TOKEN}\n", credential.stdout)
        for name in ("GH_CONFIG_DIR", "GIT_CONFIG_GLOBAL"):
            path = Path(self.runtime_env[name])
            self.assertEqual(path.stat().st_uid, 10000)
            self.assertEqual(path.stat().st_mode & 0o077, 0)
        self.assertEqual((self.source / "gh/hosts.yml").stat().st_uid, 1000)
        self.assertEqual((self.source / "gh/hosts.yml").stat().st_mode & 0o777, 0o600)
        self.assertNotIn(TOKEN, Path(self.runtime_env["GIT_CONFIG_GLOBAL"]).read_text())

    def test_github_ssh_remotes_use_https_without_affecting_other_hosts(self):
        self.seed()
        for url, expected in (
            ("git@github.com:owner/private.git", "https://github.com/owner/private.git"),
            ("ssh://git@github.com/owner/private.git", "https://github.com/owner/private.git"),
            ("git@gitlab.com:owner/private.git", "git@gitlab.com:owner/private.git"),
        ):
            with self.subTest(url=url):
                result = self.runtime("git", "ls-remote", "--get-url", url)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
        for host, protocol in (("github.com.attacker.invalid", "https"), ("github.com", "http")):
            result = self.runtime(
                "git", "credential", "fill", input=f"protocol={protocol}\nhost={host}\n\n"
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_boot_refreshes_rotated_login_and_removes_revoked_login(self):
        self.seed()
        self.login(ROTATED)
        self.seed()
        login = self.runtime("gh", "auth", "token", "--hostname", "github.com")
        self.assertEqual(login.returncode, 0, login.stderr)
        self.assertEqual(login.stdout.strip(), ROTATED)
        shutil.rmtree(self.source / "gh")
        self.seed()
        login = self.runtime("gh", "auth", "token", "--hostname", "github.com")
        self.assertNotEqual(login.returncode, 0)
        self.assertNotIn(ROTATED, login.stdout + login.stderr)
        self.assertFalse((Path(self.runtime_env["GH_CONFIG_DIR"]) / "hosts.yml").exists())


if __name__ == "__main__":
    if "--container" in sys.argv:
        sys.argv.remove("--container")
        unittest.main()
    else:
        # Borrow only the shared Nix store, never real homes, keys or credentials.
        cid = subprocess.check_output(
            ["docker", "compose", "ps", "-q", "frontdoor"], text=True
        ).strip()
        container = json.loads(subprocess.check_output(["docker", "inspect", cid]))[0]
        nix = next(m for m in container["Mounts"] if m["Destination"] == "/nix")
        root = Path(__file__).resolve().parent.parent
        sys.exit(subprocess.call([
            "docker", "run", "--rm", "--network=none",
            "-v", f"{nix['Name']}:/nix:ro",
            "-v", f"{root / 'patches/buzz/opc-gh-seed.sh'}:/usr/local/bin/opc-gh-seed.sh:ro",
            "-v", f"{Path(__file__).resolve()}:/test.py:ro",
            "--entrypoint", "/usr/bin/python3", container["Config"]["Image"],
            "/test.py", "--container", *sys.argv[1:],
        ]))
