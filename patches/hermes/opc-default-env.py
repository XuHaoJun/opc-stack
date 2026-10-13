#!/usr/bin/env python3
"""Seed default-profile credentials for the scoped multiplex gateway."""
import json
import os
from pathlib import Path
import re
import sys
import tempfile

from agent.secret_scope import load_env_file


def sync_default_env(path: Path) -> None:
    current = load_env_file(path)
    updates = {}
    # Compose owns the listener credential, including rotation/revocation.
    if "API_SERVER_KEY" in os.environ:
        value = os.environ["API_SERVER_KEY"]
        if current.get("API_SERVER_KEY") != value:
            updates["API_SERVER_KEY"] = value
    # Provider credentials remain dashboard-editable after initial seeding,
    # just like the expert profile. Never copy another profile's credentials.
    for name in (
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENCODE_API_KEY",
        "ANTHROPIC_API_KEY", "GOOGLE_API_KEY", "OPENROUTER_API_KEY", "GROQ_API_KEY",
        "DEEPSEEK_API_KEY", "XAI_API_KEY",
    ):
        value = os.environ.get(name)
        if name not in current and value:
            updates[name] = value
    if updates or not path.exists():
        text = path.read_text(encoding="utf-8") if path.exists() else ""
        lines = []
        for line in text.splitlines():
            assignment = re.match(r"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=", line)
            if assignment is None or assignment[1] not in updates:
                lines.append(line)
        lines.extend(f"{name}={json.dumps(value, ensure_ascii=False)}" for name, value in updates.items())
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".env.opc-", delete=False) as handle:
            temporary = Path(handle.name)
            try:
                handle.write("\n".join(lines) + ("\n" if lines else ""))
                handle.close()
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
        print("[hermes] reconciled default-profile scoped credentials")
    path.chmod(0o600)


if __name__ == "__main__":
    sync_default_env(Path(sys.argv[1]))
