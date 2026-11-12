#!/usr/bin/env python3
"""Exercise the synced Git config with real Git/gh; no network or real secrets."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
TOKEN = "fixture-github-token-not-a-secret"


class GitHubGitAuth(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="opc-github-git-auth-")
        cls.addClassCleanup(cls.scratch.cleanup)
        cls.root = Path(cls.scratch.name)
        source = cls.root / "source"
        destination = cls.root / "destination"
        source.mkdir()
        destination.mkdir()
        (source / "gitconfig").write_text(
            '[user]\n name = Fixture\n email = fixture@example.invalid\n'
            '[credential]\n helper = host-only-helper\n', encoding="utf-8"
        )
        # Run the actual hook in the same image and mount layout as host-sync.
        for _ in range(2):
            subprocess.run([
                "docker", "run", "--rm", "--network=none",
                "--user", f"{os.getuid()}:{os.getgid()}",
                "-v", f"{source}:/src:ro", "-v", f"{destination}:/dst",
                "-v", f"{ROOT / 'scripts/hooks/gitconfig.sh'}:/hook.sh:ro",
                "alpine:3.20", "sh", "/hook.sh",
            ], check=True, capture_output=True, text=True)
        cls.config = destination / "git/config"
        home = cls.root / "home"
        home.mkdir()
        gh_config = cls.root / "gh"
        gh_config.mkdir()
        cls.env = {
            "PATH": os.environ["PATH"], "HOME": str(home),
            "GIT_CONFIG_GLOBAL": str(cls.config), "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", "GH_CONFIG_DIR": str(gh_config),
            "GH_PROMPT_DISABLED": "1",
        }

    def fill(self, host="github.com", protocol="https", **env):
        return subprocess.run(
            ["git", "credential", "fill"],
            input=f"protocol={protocol}\nhost={host}\n\n",
            capture_output=True, text=True, cwd=self.root,
            env={**self.env, **env},
        )

    def test_plain_git_uses_environment_token_without_persisting_it(self):
        result = self.fill(GITHUB_TOKEN=TOKEN)
        self.assertEqual(result.returncode, 0, result.stderr)
        credential = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(credential["password"], TOKEN)
        self.assertTrue(credential["username"])
        self.assertNotIn(TOKEN, self.config.read_text(encoding="utf-8"))

    def test_plain_git_uses_synced_gh_login_without_environment_token(self):
        (Path(self.env["GH_CONFIG_DIR"]) / "hosts.yml").write_text(
            f"github.com:\n    user: fixture\n    oauth_token: {TOKEN}\n"
            "    git_protocol: ssh\n", encoding="utf-8"
        )
        result = self.fill()
        self.assertEqual(result.returncode, 0, result.stderr)
        credential = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(credential["password"], TOKEN)

    def test_token_is_not_offered_outside_github_https(self):
        for host, protocol in [
            ("gitlab.com", "https"),
            ("github.com.attacker.invalid", "https"),
            ("github.com", "http"),
        ]:
            with self.subTest(host=host, protocol=protocol):
                result = self.fill(host, protocol, GITHUB_TOKEN=TOKEN)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(TOKEN, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
