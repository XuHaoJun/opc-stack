"""The `buzz` CLI client.

Two things here are security-relevant, not convenience:

* the notifier key is passed explicitly with `--private-key`, and the child
  environment is stripped of `BUZZ_AUTH_TAG` and `BUZZ_PRIVATE_KEY`. The
  attestation tag is cryptographically bound to the front door's key; handing
  it to a different key makes the CLI reject every command ("signature failed
  verification"), and inheriting an ambient key would silently post as somebody
  else.
* errors are classified instead of string-matched by callers. `not_member` in
  particular is what sends a delivery down the fallback ladder.

Content goes on stdin (`--content -`) so ticket titles with backticks, `$` or
newlines never pass through a shell or argv parsing.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping

DEFAULT_TIMEOUT = 30.0
_TAG_KEY = re.compile(r"^[a-z0-9-]{1,32}$")


@dataclass(frozen=True)
class SendResult:
    event_id: str
    accepted: bool


class BuzzError(Exception):
    def __init__(self, kind: str, message: str) -> None:
        self.kind = kind
        self.message = message
        super().__init__(f"buzz error ({kind}): {message}")


class Buzz:
    def __init__(
        self,
        relay_url: str,
        nsec_path: str | Path,
        runner: Callable[..., Any] = subprocess.run,
        env: Mapping[str, str] | None = None,
        timeout: float = DEFAULT_TIMEOUT,
        binary: str = "buzz",
    ) -> None:
        self.relay_url = relay_url
        self._runner = runner
        self._timeout = timeout
        self._binary = binary

        path = Path(nsec_path)
        try:
            self._nsec = path.read_text().strip()
        except OSError as exc:
            raise BuzzError("key", f"cannot read notifier key {path}: {exc.strerror}") from None
        if not self._nsec:
            raise BuzzError("key", f"notifier key {path} is empty")

        base_env = dict(os.environ if env is None else env)
        base_env.pop("BUZZ_AUTH_TAG", None)
        base_env.pop("BUZZ_PRIVATE_KEY", None)
        self._env = base_env

    # ── transport ────────────────────────────────────────────────────────
    def _args(self, *parts: str) -> list[str]:
        return [
            self._binary,
            "--relay",
            self.relay_url,
            "--private-key",
            self._nsec,
            *parts,
        ]

    def _sanitize(self, text: str) -> str:
        text = text.replace(self._nsec, "***")
        return text[:500]

    def _error(self, returncode: int, stdout: str, stderr: str) -> BuzzError:
        message = self._sanitize((stderr or stdout).strip())
        if "restricted: not a channel member" in message:
            return BuzzError("not_member", message)
        if returncode == 3 or "auth_error" in message:
            return BuzzError("auth", message)
        if returncode == 1:
            return BuzzError("usage", message)
        return BuzzError("relay", message)

    def _run(self, *parts: str, stdin: str | None = None) -> str:
        try:
            proc = self._runner(
                self._args(*parts),
                input=stdin,
                capture_output=True,
                text=True,
                timeout=self._timeout,
                env=self._env,
            )
        except subprocess.TimeoutExpired:
            raise BuzzError("timeout", "buzz CLI timed out") from None
        if proc.returncode != 0:
            raise self._error(proc.returncode, proc.stdout or "", proc.stderr or "")
        return proc.stdout or ""

    @staticmethod
    def _json(stdout: str) -> Any:
        try:
            return json.loads(stdout)
        except ValueError:
            raise BuzzError("cli", f"unparseable CLI output: {stdout[:120]!r}") from None

    # ── messages ─────────────────────────────────────────────────────────
    def send(
        self,
        channel: str,
        content: str,
        reply_to: str | None = None,
        tags: Mapping[str, str] | None = None,
    ) -> SendResult:
        parts = ["messages", "send", "--channel", channel, "--content", "-"]
        if reply_to:
            parts += ["--reply-to", reply_to]
        for key, value in (tags or {}).items():
            if not _TAG_KEY.match(key):
                raise BuzzError("usage", f"invalid tag key {key!r}")
            if "\n" in value or "\r" in value:
                raise BuzzError("usage", f"invalid tag value for {key!r}")
            parts += ["--tag", f"{key}={value}"]

        payload = self._json(self._run(*parts, stdin=content))
        event_id = str((payload or {}).get("event_id") or "")
        accepted = bool((payload or {}).get("accepted"))
        if not event_id or not accepted:
            raise BuzzError("relay", f"message not accepted: {payload}")
        return SendResult(event_id=event_id, accepted=accepted)

    def messages(self, channel: str, since: int | None = None, limit: int = 200) -> list[dict]:
        parts = ["messages", "get", "--channel", channel, "--limit", str(limit)]
        if since is not None:
            parts += ["--since", str(int(since))]
        data = self._json(self._run(*parts))
        return data if isinstance(data, list) else []

    # ── channels / identity ──────────────────────────────────────────────
    def channels(self) -> list[dict]:
        data = self._json(self._run("channels", "list"))
        return data if isinstance(data, list) else []

    def create_channel(self, name: str, visibility: str = "open") -> dict:
        data = self._json(
            self._run(
                "channels",
                "create",
                "--name",
                name,
                "--type",
                "stream",
                "--visibility",
                visibility,
            )
        )
        return data if isinstance(data, dict) else {}

    def set_profile(self, name: str, about: str) -> None:
        self._run("users", "set-profile", "--name", name, "--about", about)


CONTROL_CHANNEL_NAME = "opc-control"


def resolve_control_channel(cfg, client: "Buzz", store) -> str:
    """The one channel owner commands are read from.

    Never inferred from "wherever the owner happened to post": that would make
    any channel an authorization surface. Order: explicit env, an existing
    channel with the reserved name, then create it. The id is persisted so a
    rename or a second lookup cannot silently pick a different channel later.
    """
    if cfg.control_channel:
        store.set_meta("control_channel", cfg.control_channel)
        return cfg.control_channel

    cached = store.get_meta("control_channel")
    if cached:
        return cached

    for channel in client.channels():
        if str(channel.get("name") or "").strip().lower() == CONTROL_CHANNEL_NAME:
            channel_id = str(channel.get("channel_id") or "")
            if channel_id:
                store.set_meta("control_channel", channel_id)
                return channel_id

    created = client.create_channel(CONTROL_CHANNEL_NAME)
    channel_id = str(created.get("channel_id") or created.get("id") or "")
    if not channel_id:
        raise BuzzError("cli", "creating the control channel returned no id")
    store.set_meta("control_channel", channel_id)
    return channel_id
