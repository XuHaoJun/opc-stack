"""Observability for dropped memory-ingress candidates.

WHY THIS EXISTS: without it, "is the gate tuned correctly?" has no answer — which is
the exact complaint users make about opaque memory ("I cleared it and it still pulls
from somewhere I can't find"). Spec 7.2.

WHY IT STORES METADATA, NOT CONTENT: writing the full dropped text would create a
second sensitive-data lifecycle to manage, which is what this design is trying to
avoid. A hash answers "was this dropped before / has it changed" without keeping the
text. Full content is debug-only and short-lived.

ROTATION copies the house pattern for the system's other append-only JSONL
(MemoryCore/src/utils/memory-cleaner.ts): date-shard the filename, delete whole shards
by regex-parsed date, never rewrite lines inside a file, keep a retention floor, and
emit one structured summary per sweep. Deliberately NOT persona.backupCount (its
BackupManager is never constructed in service mode, so the key is dead) and NOT
offload/reclaimer.ts's truncate(path, 0) (discards all history, no generations).
"""
import hashlib
import json
import os
import re
import time
from datetime import date, datetime, timedelta, timezone
from typing import Optional

_SHARD_RE = re.compile(r"^memory-ingress-(\d{4})-(\d{2})-(\d{2})\.jsonl$")
_DEBUG_SHARD_RE = re.compile(r"^memory-ingress-debug-(\d{4})-(\d{2})-(\d{2})\.jsonl$")
_PREVIEW_CHARS = 64
_MIN_RETAIN_SHARDS = 3


class IngressLog:
    def __init__(self, directory: str, *, retention_days: int = 30,
                 debug_retention_days: int = 2, debug: bool = False):
        self._dir = directory
        self._retention_days = retention_days
        self._debug_retention_days = debug_retention_days
        self._debug = debug
        os.makedirs(self._dir, exist_ok=True)

    def _shard(self, prefix: str = "memory-ingress") -> str:
        return os.path.join(
            self._dir, f"{prefix}-{date.today().isoformat()}.jsonl")

    def _append(self, path: str, row: dict) -> None:
        # Create 0600 before writing: the file may hold sensitive previews, and a
        # root-created file is unreadable to the runtime uid — a failure that does not
        # look like a permissions problem (AGENTS.md invariant 3b).
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (json.dumps(row, ensure_ascii=False) + "\n").encode("utf-8"))
        finally:
            os.close(fd)

    def record(self, reason: str, session_id: str, agent_id: str, content: str,
               *, sender: Optional[str] = None,
               event_id: Optional[str] = None) -> None:
        text = content or ""
        row = {
            "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "reason": reason,
            "session_id": session_id,
            "agent_id": agent_id,
            "sender": sender,
            "event_id": event_id,
            "len": len(text),
            "content_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "preview": text[:_PREVIEW_CHARS],
        }
        self._append(self._shard(), row)
        if self._debug:
            self._append(self._shard("memory-ingress-debug"),
                         {**row, "content": text})

    def sweep(self) -> dict:
        """Delete expired shards. Returns a summary dict; log it as one line."""
        summary = {"event": "ingress_log_sweep", "deleted": 0, "kept": 0, "skipped": 0}
        for pattern, days in ((_SHARD_RE, self._retention_days),
                              (_DEBUG_SHARD_RE, self._debug_retention_days)):
            shards = []
            for name in os.listdir(self._dir):
                m = pattern.match(name)
                if m:
                    shards.append((name, date(*(int(g) for g in m.groups()))))
                elif not _SHARD_RE.match(name) and not _DEBUG_SHARD_RE.match(name):
                    summary["skipped"] += 1
            # Retention floor: never prune down to nothing just because the corpus is
            # young — the same reasoning as memory-cleaner's MIN_RETAIN_L0.
            if len(shards) <= _MIN_RETAIN_SHARDS:
                summary["kept"] += len(shards)
                continue
            cutoff = date.today() - timedelta(days=days)
            for name, day in shards:
                if day < cutoff:
                    try:
                        os.unlink(os.path.join(self._dir, name))
                        summary["deleted"] += 1
                    except OSError:
                        summary["skipped"] += 1
                else:
                    summary["kept"] += 1
        return summary
