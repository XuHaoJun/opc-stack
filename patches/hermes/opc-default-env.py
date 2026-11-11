#!/usr/bin/env python3
"""Reconcile profile credentials without overwriting operator-owned values."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

from agent.secret_scope import load_env_file


def write_private(path: Path, text: str) -> None:
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=f".{path.name}.opc-", delete=False) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(text)
            handle.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def sync_default_env(path: Path, *, provider_only: bool = False) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    current = load_env_file(path)
    ledger = path.parent / ".opc-provider-seed.json"
    previous = json.loads(ledger.read_text(encoding="utf-8")) if ledger.exists() else {}
    owned = dict(previous)
    updates = {}
    # Compose owns the listener credential, including rotation/revocation.
    if not provider_only and "API_SERVER_KEY" in os.environ:
        value = os.environ["API_SERVER_KEY"]
        if current.get("API_SERVER_KEY") != value:
            updates["API_SERVER_KEY"] = value
    names = ("OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENCODE_API_KEY")
    if not provider_only:
        names += ("ANTHROPIC_API_KEY", "GOOGLE_API_KEY", "OPENROUTER_API_KEY",
                  "GROQ_API_KEY", "DEEPSEEK_API_KEY", "XAI_API_KEY")
    for name in names:
        if name not in os.environ:
            continue
        value = os.environ[name]
        existing = current.get(name)
        digest = hashlib.sha256((existing or "").encode()).hexdigest()
        # Adopt matching nonempty pre-ledger values. Differing unknown values
        # and deliberate blanks belong to the operator, not to OPC.
        managed = (name not in current and bool(value)) or (
            name in current and (
                previous.get(name) == digest or (bool(value) and existing == value)
            )
        )
        if managed:
            if existing != value:
                updates[name] = value
            owned[name] = hashlib.sha256(value.encode()).hexdigest()
    # A provider is a credential/endpoint pair. Decide before publication:
    # preserving either operator field must not rotate the other half.
    ready = all(updates.get(name, current.get(name, "")) == os.environ[name]
                for name in ("OPENAI_API_KEY", "OPENAI_BASE_URL") if name in os.environ)
    if not ready:
        for name in ("OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENCODE_API_KEY"):
            updates.pop(name, None)
            if name in previous:
                owned[name] = previous[name]
            else:
                owned.pop(name, None)
    if updates or not path.exists():
        text = path.read_text(encoding="utf-8") if path.exists() else ""
        lines = []
        for line in text.splitlines():
            assignment = re.match(r"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=", line)
            if assignment is None or assignment[1] not in updates:
                lines.append(line)
        lines.extend(f"{name}={json.dumps(value, ensure_ascii=False)}" for name, value in updates.items())
        path.parent.mkdir(parents=True, exist_ok=True)
        write_private(path, "\n".join(lines) + ("\n" if lines else ""))
        current.update(updates)
        print("[hermes] reconciled profile scoped credentials", file=sys.stderr)
    path.chmod(0o600)
    if owned != previous:
        write_private(ledger, json.dumps(owned, sort_keys=True) + "\n")
    if not ready:
        print("[hermes] WARNING operator-owned or pre-ledger provider credentials differ "
              "from Compose; preserving this profile's model/endpoint (see SETUP.md)",
              file=sys.stderr)
    return ready


if __name__ == "__main__":
    ready = sync_default_env(Path(sys.argv[1]), provider_only="--provider-only" in sys.argv[2:])
    if "--stack-status" in sys.argv[2:]:
        print("1" if ready else "0")
