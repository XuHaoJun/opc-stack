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

from . import config, events, labels
from .config import iso, parse_iso  # re-exported: tests and callers use poller.iso

POLL_OVERLAP_SECONDS = 10.0
PAGE_SIZE = 100
MAX_PAGES = 50
ORIGIN_CACHE_SECONDS = 3600.0

_TERMINAL_STATUSES = {"done", "blocked", "cancelled"}
# A failed run on a blocked ticket is exactly the event Hermes needs: Paperclip
# blocks the ticket *because* the run failed. Only a successful or abandoned
# ticket makes a failure historical.
_QUIET_FAILURE_STATUSES = {"done", "cancelled"}
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
        self._label_names: dict[str, str] | None = None
        self._agents_by_id: dict[str, dict] | None = None

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
        emitted += self._sweep_runs(now)
        return emitted

    def reconcile(self, now: float | None = None) -> int:
        now = self._clock() if now is None else now
        since = iso(now - self.cfg.reconcile_lookback_hours * 3600.0)
        # Pre-cutover history is not "missed work": the baseline deliberately
        # recorded it as observed-not-delivered, and replaying it ten minutes
        # after a first install would re-announce the board into old threads.
        return self._recover(since, now, watermark=self.store.bootstrap_at())

    def issue_track(self, issue: Mapping[str, Any]) -> str:
        """Track from labels, falling back to the assignee (legacy tickets)."""
        names = {self._label_names_by_id().get(str(i), "") for i in (issue.get("labelIds") or [])}
        agent = self._agents_map().get(str(issue.get("assigneeAgentId") or ""))
        return labels.track_of([name for name in names if name], agent)

    def backfill_labels(self) -> int:
        """Label open tickets that predate the track dimension.

        Idempotent and driven by the assignee, because the alternative — parsing
        prose — makes an untrusted input part of the policy resolver.
        """
        ensured = labels.ensure_labels(self.pc)
        self._label_names = {label_id: name for name, label_id in ensured.items()}
        changed = 0
        for status in _OPEN_STATUSES:
            for issue in self.pc.issues_with_status(status, limit=PAGE_SIZE):
                self._check_track_conflict(issue)
                current = [str(i) for i in (issue.get("labelIds") or [])]
                track_ids = {label_id for name, label_id in ensured.items() if name.startswith("track:")}
                if any(label_id in track_ids for label_id in current):
                    continue
                agent = self._agents_map().get(str(issue.get("assigneeAgentId") or ""))
                track = labels.track_of(set(), agent)
                if track == "unknown":
                    self._policy_violation(issue, "unlabeled_track")
                    continue
                desired = labels.labels_for_markers(
                    {"lane": "engineering" if track == "core" else "prototype"}
                )
                ids = [ensured[name] for name in desired if name in ensured]
                if not ids:
                    continue
                self.pc.patch_issue(str(issue["id"]), {"labelIds": current + ids})
                changed += 1
        return changed

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

        self._check_track_conflict(issue)
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

    def _check_track_conflict(self, issue: Mapping[str, Any]) -> None:
        names = {self._label_names_by_id().get(str(i), "") for i in (issue.get("labelIds") or [])}
        track_names = {name for name in names if name.startswith("track:")}
        if len(track_names) > 1:
            self._policy_violation(issue, "conflicting_track")
            return
        if len(track_names) == 1:
            label_track = next(iter(track_names)).split(":", 1)[1]
            agent = self._agents_map().get(str(issue.get("assigneeAgentId") or ""))
            agent_track = labels.track_of(set(), agent)
            if agent_track in ("core", "lab") and agent_track != label_track:
                # §6.4/§19.4: a Lab ticket on the engineering agent is not
                # covered by the Lab lock. Report it rather than let it run
                # silently outside the track's policy.
                self._policy_violation(issue, "cross_track_assignment")

    def _policy_violation(self, issue: Mapping[str, Any], reason: str) -> None:
        issue_id = str(issue["id"])
        now = self._clock()
        event = events.Event(
            schema_version=events.SCHEMA_VERSION,
            event_id=events.health_event_id(issue_id, "policy_" + reason, 0),
            event_type=events.POLICY_VIOLATION,
            source="opc",
            company_id=self._company(),
            project_id=issue.get("projectId"),
            issue_id=issue_id,
            issue_identifier=issue.get("identifier"),
            run_id=None,
            status=reason,
            occurred_at=str(issue.get("updatedAt") or iso(now)),
            observed_at=iso(now),
            artifact_url=None,
            origin_channel_id=(self.store.get_origin(issue_id) or (None, None))[0],
            origin_event_id=(self.store.get_origin(issue_id) or (None, None))[1],
            correlation_id=f"{issue.get('identifier') or issue_id}-{reason}",
            track="unknown",
            issue_title=issue.get("title"),
        )
        self.store.enqueue_event(event, now)

    def _label_names_by_id(self) -> dict[str, str]:
        if self._label_names is None:
            ensured = labels.ensure_labels(self.pc)
            self._label_names = {label_id: name for name, label_id in ensured.items()}
        return self._label_names

    def _agents_map(self) -> dict[str, dict]:
        if self._agents_by_id is None:
            self._agents_by_id = {str(a.get("id")): a for a in self.pc.agents()}
        return self._agents_by_id

    def _sweep_runs(self, now: float) -> int:
        """`paperclip.issue.failed`, independent of the issue-poll page.

        Requirement §3.5 lists this event; §3.7 forbids losing events. Scanning
        only the issues touched by the current issue page silently missed a
        failed run whose ticket row never changed, so the source is the company
        run list, cursor-bounded (with overlap) and deduped by event id.

        The list row names the id `id` (`runId` is null there); both shapes are
        accepted, and a row without either is skipped.
        """
        cursor = self.store.get_meta("run_sweep_cursor")
        rows = self.pc.heartbeat_runs(limit=self.cfg.run_sweep_limit)
        finished = [str(row.get("finishedAt") or "") for row in rows]
        finished = [value for value in finished if value]

        if cursor is None:
            # First run is a baseline: remember where we are, emit nothing.
            if finished:
                self.store.set_meta("run_sweep_cursor", max(finished))
            return 0

        since = iso(parse_iso(cursor) - self.cfg.run_sweep_overlap_seconds)
        latest = cursor
        emitted = 0
        issues: dict[str, dict] = {}

        for run in rows:
            observed = str(run.get("finishedAt") or "")
            if not observed or observed < since:
                continue
            if observed > latest:
                latest = observed
            status = str(run.get("status") or "")
            admission_cancelled = False
            if status not in _RUN_FAILURES:
                if status == "cancelled":
                    # A hard lock makes Paperclip cancel not-yet-started runs
                    # with this error code; spec §12 promised that is reported,
                    # not silent.
                    try:
                        detail = self.pc.run(str(run.get("id") or run.get("runId") or ""))
                    except Exception:
                        detail = {}
                    admission_cancelled = str(detail.get("errorCode") or "") == "agent_not_invokable"
                if not admission_cancelled:
                    continue
            if not str(run.get("runId") or run.get("id") or "").strip():
                continue
            issue_id = str(run.get("issueId") or "")
            if not issue_id:
                continue  # company-scope run: no ticket to report against
            if issue_id not in issues:
                try:
                    issues[issue_id] = dict(self.pc.issue(issue_id))
                except Exception:
                    issues[issue_id] = {}
            issue = issues[issue_id]
            if not issue or str(issue.get("status")) in _QUIET_FAILURE_STATUSES:
                continue
            event_type = events.ADMISSION_CANCELLED if admission_cancelled else events.ISSUE_FAILED
            emitted += int(self.store.enqueue_event(self._run_event(issue, run, now, event_type), now))

        if latest != cursor:
            self.store.set_meta("run_sweep_cursor", latest)
        return emitted

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
            track=self.issue_track(issue),
            issue_title=issue.get("title"),
        )

    def _run_event(self, issue: Mapping[str, Any], run: Mapping[str, Any], now: float,
                   event_type: str = events.ISSUE_FAILED):
        issue_id = str(issue["id"])
        identifier = issue.get("identifier")
        status = str(run.get("status") or "")
        occurred = str(run.get("finishedAt") or run.get("updatedAt") or iso(now))
        channel, anchor = self.resolve_origin(issue_id)
        run_id_value = str(run.get("runId") or run.get("id") or "")

        event_kind = status if event_type == events.ISSUE_FAILED else "admission_cancelled"
        return events.Event(
            schema_version=events.SCHEMA_VERSION,
            event_id=events.run_event_id(run_id_value, event_kind),
            event_type=event_type,
            source="paperclip",
            company_id=self._company(),
            project_id=issue.get("projectId"),
            issue_id=issue_id,
            issue_identifier=identifier,
            run_id=run_id_value,
            status=status,
            occurred_at=occurred,
            observed_at=iso(now),
            artifact_url=None,
            origin_channel_id=channel,
            origin_event_id=anchor,
            correlation_id=f"{identifier or issue_id}-run-{run_id_value[:8]}",
            track=self.issue_track(issue),
            issue_title=issue.get("title"),
        )

    # ── recovery ─────────────────────────────────────────────────────────
    def _recover(self, since_iso: str, now: float, watermark: str | None = None) -> int:
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
                fresh = watermark is None or (events.terminal_ts(issue) or "") > watermark
                if event_type is not None and fresh:
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
