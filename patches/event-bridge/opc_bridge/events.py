"""The versioned event contract.

These are OPC's event names, not Paperclip's. Paperclip has no `completed`
event; it has a status column. The mapping is ours, kept in one place so an
upstream status rename is a one-line change plus a test.

Ids are deterministic, and *never* keyed on the issue alone: an issue can be
re-opened and completed again, and a dedupe key that swallowed the second
completion would lose real work. The terminal timestamp is part of the key —
Paperclip re-stamps `completedAt`/`cancelledAt` on every terminal write, so a
genuine re-completion gets a new id while a replayed delivery of the same
transition keeps the old one.
"""

from __future__ import annotations

import hashlib
from dataclasses import asdict, dataclass, fields
from typing import Any, Mapping

SCHEMA_VERSION = 1

ISSUE_COMPLETED = "paperclip.issue.completed"
ISSUE_BLOCKED = "paperclip.issue.blocked"
ISSUE_CANCELLED = "paperclip.issue.cancelled"
ISSUE_FAILED = "paperclip.issue.failed"

HEALTH_SLOW = "opc.run.slow"
HEALTH_STALLED = "opc.run.stalled"
HEALTH_LOST = "opc.run.lost"
HEALTH_RECOVERED = "opc.run.recovered"
ADMISSION_CANCELLED = "opc.run.admission_cancelled"
POLICY_VIOLATION = "opc.policy.violation"

_TERMINAL = {
    "done": ISSUE_COMPLETED,
    "blocked": ISSUE_BLOCKED,
    "cancelled": ISSUE_CANCELLED,
}

_LABEL = {
    ISSUE_COMPLETED: "完成",
    ISSUE_BLOCKED: "阻塞",
    ISSUE_CANCELLED: "已取消",
    ISSUE_FAILED: "執行失敗",
    HEALTH_SLOW: "進展緩慢",
    HEALTH_STALLED: "疑似停滯",
    HEALTH_LOST: "狀態不一致",
    HEALTH_RECOVERED: "已恢復",
    ADMISSION_CANCELLED: "准入取消",
    POLICY_VIOLATION: "政策違規",
}


@dataclass(frozen=True)
class Event:
    schema_version: int
    event_id: str
    event_type: str
    source: str
    company_id: str
    project_id: str | None
    issue_id: str | None
    issue_identifier: str | None
    run_id: str | None
    status: str | None
    occurred_at: str
    observed_at: str
    artifact_url: str | None
    origin_channel_id: str | None
    origin_event_id: str | None
    correlation_id: str
    track: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "Event":
        known = {f.name for f in fields(cls)}
        return cls(**{key: data[key] for key in data if key in known})


def _digest(payload: str) -> str:
    return "evt_" + hashlib.sha256(payload.encode("utf-8")).hexdigest()[:12]


def issue_event_id(issue_id: str, status: str, terminal_ts: str) -> str:
    return _digest(f"issue|{issue_id}|{status}|{terminal_ts}")


def run_event_id(run_id: str, status: str) -> str:
    return _digest(f"run|{run_id}|{status}")


def health_event_id(run_id: str, kind: str, bucket: int) -> str:
    return _digest(f"health|{run_id}|{kind}|{bucket}")


def terminal_ts(issue: Mapping[str, Any]) -> str | None:
    """The timestamp that makes a terminal observation unique.

    `blocked` has no dedicated column in Paperclip's issue row, so it falls
    back to `updatedAt`; the poller stores the resolved value in issue_state,
    which is what makes a re-asserted `blocked` detectable.
    """
    status = issue.get("status")
    if status == "done":
        return issue.get("completedAt")
    if status == "cancelled":
        return issue.get("cancelledAt")
    if status == "blocked":
        return issue.get("blockedTransitionAt") or issue.get("updatedAt")
    return None


def classify_issue(
    previous: Mapping[str, Any] | None, issue: Mapping[str, Any]
) -> str | None:
    """Return the event type for a transition, or None.

    `previous is None` means "first time we see this issue" — a baseline
    observation. It deliberately emits nothing: cutover must not replay the
    whole board into the operator's channels.
    """
    if previous is None:
        return None

    status = issue.get("status")
    previous_status = previous.get("status")

    if status == previous_status:
        # `blocked` can be re-asserted (or its blockers changed) while the
        # status string stays the same; Paperclip bumps the transition time.
        if status == "blocked" and terminal_ts(issue) != terminal_ts(previous):
            return ISSUE_BLOCKED
        return None

    return _TERMINAL.get(str(status))


def render_message(event: Event, issue: Mapping[str, Any], public_url: str) -> str:
    identifier = str(issue.get("identifier") or event.issue_identifier or event.correlation_id)
    title = str(issue.get("title") or "").strip()
    label = _LABEL.get(event.event_type, event.event_type)

    lines = [f"Paperclip 事件 · {identifier} · {label}"]
    if title:
        lines.append(title)
    if public_url:
        lines.append(f"Ticket: {public_url}/issues/{identifier}")
    else:
        lines.append(f"Ticket: {identifier}")
    if event.artifact_url:
        lines.append(f"成果: {event.artifact_url}")
    lines.append("")
    lines.append(f"OPC_EVENT: {event.event_id}")
    return "\n".join(lines)


def event_tags(event: Event) -> dict[str, str]:
    return {
        "opc-event": event.event_id,
        "opc-event-type": event.event_type,
        "opc-issue": str(event.issue_identifier or event.issue_id or ""),
        "opc-track": event.track,
    }
