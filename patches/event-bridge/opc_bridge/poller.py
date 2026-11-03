"""Issue/run observation -> events.

Three entry points, deliberately different:

  bootstrap()  first boot. Seeds the status of every open issue and starts the
               cursor. It emits nothing: re-announcing the board on cutover is
               noise in threads nobody is watching.
  tick()       steady state. Pages Paperclip's `updatedSince` stream with a
               small overlap, emits only on a status transition.
  reconcile()  recovery. Re-reads terminal issues in a lookback window and
               re-enqueues anything the outbox does not already know about.
               `backfill(since)` is the same thing with an explicit window,
               for an operator who wants history on purpose.

`event_id` is the dedupe key everywhere downstream, and every enqueue goes
through `Store.enqueue_event` (INSERT OR IGNORE), so running tick, reconcile
and backfill over the same rows can never deliver twice.
"""

from __future__ import annotations

import re
from typing import Any, Callable, Mapping

from . import config, events
from .config import iso, parse_iso  # re-exported: tests and callers use poller.iso

POLL_OVERLAP_SECONDS = 10.0
PAGE_SIZE = 100
MAX_PAGES = 50
ORIGIN_CACHE_SECONDS = 3600.0

_TERMINAL_STATUSES = {"done", "blocked", "cancelled"}
_OPEN_STATUSES = ("backlog", "todo", "in_progress", "in_review")
_RUN_FAILURES = {"failed", "timed_out"}

_UUID = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
_CHANNEL_MARKER = re.compile(r"BUZZ_CHANNEL:\s*([0-9a-fA-F-]{36})")
_ANCHOR_MARKER = re.compile(r"BUZZ_EVENT:\s*([0-9a-fA-F]{16,64})")
_PORT_URL = re.compile(r"https?://[A-Za-z0-9._-]+:[0-9]{2,5}(?:/[^\s)\"'`<>]*)?" )
_GITHUB_REPO = re.compile(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
_FORGE_HOSTS = {"github.com", "gitlab.com", "bitbucket.org"}


def _trusted_marker_author(comment: Mapping[str, Any]) -> bool:
    """Who may write a routing marker.

    Paperclip comments carry no Nostr key: the front door writes them through
    the board key (authorType=user) and an agent that files its own ticket
    writes them as authorType=agent. Anything else (system rows, foreign
    integrations) is ignored. This is a routing hint, not authorization — a
    forged marker can only point a notice at another channel/thread.
    """
    return comment.get("authorType") in ("user", "agent")


def _marker(comments: list[dict], pattern: re.Pattern[str], validate: Callable[[str], bool]) -> str | None:
    for comment in comments:
        if not _trusted_marker_author(comment):
            continue
        match = pattern.search(str(comment.get("body") or ""))
        if match and validate(match.group(1)):
            return match.group(1)
    return None


def extract_artifact(comments: list[dict]) -> str | None:
    """The deliverable link, taken from comments.

    A registered preview URL (host:port) wins over a forge link: tickets
    legitimately mention repositories in passing (a skill to install, a
    library to copy from), and announcing that as the result was a real bug in
    the watcher this replaces. Only a ticket with no preview falls through to a
    repository root, which is the engineering lane.
    """
    bodies = [str(comment.get("body") or "") for comment in comments]

    for body in bodies:
        for match in _PORT_URL.finditer(body):
            url = match.group(0).rstrip(".,;:)]}\"'")
            host = url.split("//", 1)[-1].split("/", 1)[0].split(":", 1)[0].lower()
            if host in _FORGE_HOSTS:
                continue
            return url

    for body in bodies:
        for match in _GITHUB_REPO.finditer(body):
            # A repo root is the link; /pull/12 and /tree/main are not.
            if body[match.end() : match.end() + 1] == "/":
                continue
            return match.group(0)

    return None


class Poller:
    def __init__(
        self,
        cfg: config.Config,
        store,
        pc,
        clock: Callable[[], float] = None,
        log: Callable[..., Any] = print,
    ) -> None:
        self.cfg = cfg
        self.store = store
        self.pc = pc
        self._clock = clock or (lambda: config.now(cfg))
        self.log = log
        self._comments_cache: dict[str, list[dict]] = {}

    # ── public API ───────────────────────────────────────────────────────
    def bootstrap(self) -> None:
        if self.store.cursor() is not None:
            return

        seeded = 0
        for status in _OPEN_STATUSES:
            for issue in self.pc.issues_with_status(status, limit=PAGE_SIZE):
                self.store.upsert_issue_state(issue)
                seeded += 1

        start = self._clock() - self.cfg.cutover_lookback_hours * 3600.0
        self.store.set_cursor(iso(start), bootstrapped_at=iso(self._clock()))
        self.log(f"[poller] baseline: {seeded} open issue(s), cursor {iso(start)}")

    def tick(self, now: float | None = None) -> int:
        self.bootstrap()
        self._comments_cache.clear()
        now = self._clock() if now is None else now
        emitted = self._poll_transitions(now)
        emitted += self._observe_runs(now)
        return emitted

    def reconcile(self, now: float | None = None) -> int:
        now = self._clock() if now is None else now
        since = iso(now - self.cfg.reconcile_lookback_hours * 3600.0)
        return self._recover(since, now)

    def backfill(self, since_iso: str, now: float | None = None) -> int:
        now = self._clock() if now is None else now
        return self._recover(since_iso, now)

    def resolve_origin(self, issue_id: str) -> tuple[str | None, str | None]:
        cached = self.store.get_origin(issue_id)
        if cached is not None:
            # Markers are written when the ticket is created, so the first
            # resolution is authoritative. Caching the miss too matters: a
            # non-Buzz ticket must not cost a comments fetch on every retry.
            return cached

        comments = self._comments(issue_id)
        channel = _marker(comments, _CHANNEL_MARKER, lambda v: bool(_UUID.match(v)))
        anchor = _marker(comments, _ANCHOR_MARKER, lambda v: bool(v))
        self.store.set_origin(issue_id, channel, anchor, iso(self._clock()))
        return channel, anchor

    # ── observation ──────────────────────────────────────────────────────
    def _poll_transitions(self, now: float) -> int:
        cursor = self.store.cursor() or iso(now)
        since = iso(parse_iso(cursor) - POLL_OVERLAP_SECONDS)
        emitted = 0
        latest = cursor
        offset = 0

        for _ in range(MAX_PAGES):
            rows = self.pc.issues_updated_since(since, limit=PAGE_SIZE, offset=offset)
            if not rows:
                break

            self._touched = rows
            for issue in rows:
                emitted += self._observe_issue(issue, now)
                updated = str(issue.get("updatedAt") or "")
                if updated and updated > latest:
                    latest = updated

            if len(rows) < PAGE_SIZE:
                break
            offset += PAGE_SIZE

        if latest != cursor:
            self.store.set_cursor(latest)
        return emitted

    def _observe_issue(self, issue: Mapping[str, Any], now: float) -> int:
        issue_id = str(issue["id"])
        previous = self.store.get_issue_state(issue_id)
        previous_for_classify = None
        if previous is not None:
            terminal = previous.get("terminal_ts")
            previous_for_classify = {
                "status": previous.get("status"),
                "completedAt": terminal,
                "cancelledAt": terminal,
                "blockedTransitionAt": terminal,
                "updatedAt": terminal,
            }

        event_type = events.classify_issue(previous_for_classify, issue)
        if event_type is None and previous is None:
            # First observation of an already-terminal issue. That is history
            # (silent) only if it predates the bridge; an issue created and
            # completed between two ticks is a real transition we must report,
            # or a fast ticket would vanish from the loop forever.
            event_type = self._late_terminal_type(issue)
        emitted = 0
        if event_type is not None:
            emitted += int(self.store.enqueue_event(self._issue_event(issue, event_type, now), now))

        self.store.upsert_issue_state(dict(issue))
        return emitted

    def _late_terminal_type(self, issue: Mapping[str, Any]) -> str | None:
        status = str(issue.get("status") or "")
        event_type = {
            "done": events.ISSUE_COMPLETED,
            "blocked": events.ISSUE_BLOCKED,
            "cancelled": events.ISSUE_CANCELLED,
        }.get(status)
        if event_type is None:
            return None
        watermark = self.store.bootstrap_at()
        if watermark is None:
            return None
        seen_at = str(issue.get("createdAt") or issue.get("updatedAt") or "")
        return event_type if seen_at and seen_at > watermark else None

    def _observe_runs(self, now: float) -> int:
        """A run that failed leaves the issue open; that is its own event.

        Bounded to issues the batch already touched, because runs are only
        interesting when something just changed.
        """
        emitted = 0
        for issue in self._last_touched():
            if issue.get("status") in _TERMINAL_STATUSES:
                continue
            for run in self.pc.runs_for_issue(str(issue["id"])):
                status = str(run.get("status") or "")
                if status not in _RUN_FAILURES:
                    continue
                event = self._run_event(issue, run, now)
                emitted += int(self.store.enqueue_event(event, now))
        return emitted

    def _last_touched(self) -> list[dict]:
        return getattr(self, "_touched", [])

    # ── events ───────────────────────────────────────────────────────────
    def _issue_event(self, issue: Mapping[str, Any], event_type: str, now: float):
        issue_id = str(issue["id"])
        status = str(issue.get("status") or "")
        occurred = events.terminal_ts(issue) or str(issue.get("updatedAt") or iso(now))
        channel, anchor = self.resolve_origin(issue_id)
        artifact = extract_artifact(self._comments(issue_id)) if event_type == events.ISSUE_COMPLETED else None
        identifier = issue.get("identifier")

        return events.Event(
            schema_version=events.SCHEMA_VERSION,
            event_id=events.issue_event_id(issue_id, status, occurred),
            event_type=event_type,
            source="paperclip",
            company_id=self._company(),
            project_id=issue.get("projectId"),
            issue_id=issue_id,
            issue_identifier=identifier,
            run_id=None,
            status=status,
            occurred_at=occurred,
            observed_at=iso(now),
            artifact_url=artifact,
            origin_channel_id=channel,
            origin_event_id=anchor,
            correlation_id=f"{identifier or issue_id}-{status}",
            track=str(issue.get("track") or "unknown"),
            issue_title=issue.get("title"),
        )

    def _run_event(self, issue: Mapping[str, Any], run: Mapping[str, Any], now: float):
        issue_id = str(issue["id"])
        identifier = issue.get("identifier")
        status = str(run.get("status") or "")
        occurred = str(run.get("finishedAt") or run.get("updatedAt") or iso(now))
        channel, anchor = self.resolve_origin(issue_id)

        return events.Event(
            schema_version=events.SCHEMA_VERSION,
            event_id=events.run_event_id(str(run["id"]), status),
            event_type=events.ISSUE_FAILED,
            source="paperclip",
            company_id=self._company(),
            project_id=issue.get("projectId"),
            issue_id=issue_id,
            issue_identifier=identifier,
            run_id=str(run["id"]),
            status=status,
            occurred_at=occurred,
            observed_at=iso(now),
            artifact_url=None,
            origin_channel_id=channel,
            origin_event_id=anchor,
            correlation_id=f"{identifier or issue_id}-run-{str(run['id'])[:8]}",
            track=str(issue.get("track") or "unknown"),
            issue_title=issue.get("title"),
        )

    # ── recovery ─────────────────────────────────────────────────────────
    def _recover(self, since_iso: str, now: float) -> int:
        emitted = 0
        offset = 0
        for _ in range(MAX_PAGES):
            rows = self.pc.issues_updated_since(since_iso, limit=PAGE_SIZE, offset=offset)
            if not rows:
                break
            for issue in rows:
                status = str(issue.get("status") or "")
                event_type = {
                    "done": events.ISSUE_COMPLETED,
                    "blocked": events.ISSUE_BLOCKED,
                    "cancelled": events.ISSUE_CANCELLED,
                }.get(status)
                if event_type is not None:
                    emitted += int(
                        self.store.enqueue_event(self._issue_event(issue, event_type, now), now)
                    )
                self.store.upsert_issue_state(dict(issue))
            if len(rows) < PAGE_SIZE:
                break
            offset += PAGE_SIZE
        if emitted:
            self.log(f"[poller] recovery from {since_iso}: {emitted} event(s)")
        return emitted

    # ── helpers ──────────────────────────────────────────────────────────
    def _comments(self, issue_id: str) -> list[dict]:
        if issue_id not in self._comments_cache:
            self._comments_cache[issue_id] = list(self.pc.comments(issue_id))
        return self._comments_cache[issue_id]

    def _company(self) -> str:
        company = getattr(self.pc, "company", None)
        return str(company()) if callable(company) else ""
