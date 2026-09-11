"""Age bounding for L1 recall.

WHY CLIENT-SIDE: `/v3/atomic/search` advertises `time_start` in its request schema
(`gateway/generated/schemas.ts:191-197`) but the handler never reads it —
`handleAtomicSearch` destructures only `{query, type}` (`gateway/v2-router.ts:1192-1216`)
and `executeMemorySearch` has no time parameter at all (`core/tools/memory-search.ts:87-96`).
Sending it would have been fail-green: the knob would look wired, log normally, and do
nothing. `/v3/conversation/query`, `/v3/conversation/search` and `/v3/atomic/query` do
honour it, so the field is not dead everywhere — only on the one endpoint we call.

So the window is applied here, over `created_at`, which the response actually carries.
"""
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional


def _parse(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        stamp = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    # Naive stamps are UTC by construction (the store writes ISO-8601 Z), and comparing
    # naive against aware raises TypeError — which would take the whole recall path down.
    return stamp if stamp.tzinfo else stamp.replace(tzinfo=timezone.utc)


def recent_only(items: List[Dict[str, Any]], window_days: int, *,
                now: Optional[str] = None) -> List[Dict[str, Any]]:
    """Drop items older than ``window_days`` (<= 0 disables the window entirely).

    A missing or unparsable ``created_at`` is KEPT. This is a staleness knob, not a
    security gate: silently deleting a memory because a timestamp shape changed would be
    worse than surfacing one that is a little old, and it would be invisible.
    """
    if window_days <= 0:
        return list(items)
    reference = _parse(now) or datetime.now(timezone.utc)
    cutoff = reference - timedelta(days=window_days)
    kept: List[Dict[str, Any]] = []
    for item in items:
        stamp = _parse(item.get("created_at")) if isinstance(item, dict) else None
        if stamp is None or stamp >= cutoff:
            kept.append(item)
    return kept
