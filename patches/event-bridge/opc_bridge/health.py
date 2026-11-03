"""Run health classification and reminders.

The rule that matters most is the negative one: **this module never cancels
anything**. Suspected staleness, timeout and missing output are reasons to tell
a human, not reasons to kill a run. The code path that emits a health event has
no access to the cancel API, and a test asserts the name never appears here.

States and their evidence:
  healthy            progress within `slow`
  slow               no progress for >= slow
  suspected_stalled  no progress for >= stall AND an abnormal silence signal
  lost               definitive inconsistency (run running while its issue is
                     terminal, agent paused/terminated under a running run, or
                     the run is finished but still marked running)
  unknown            not enough visibility to say anything — `hermes_gateway`
                     runs have no pid, and guessing would page a human for a
                     healthy long-running task
"""

from __future__ import annotations

from typing import Any, Callable, Mapping

from . import config, events

ABNORMAL = {"suspicious", "critical"}


def _progress_at(run: Mapping[str, Any]) -> float | None:
    silence = run.get("outputSilence") or {}
    for value in (
        silence.get("lastOutputAt"),
        run.get("lastOutputAt"),
        run.get("lastEventAt"),
        run.get("startedAt"),
    ):
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            try:
                return config.parse_iso(value)
            except ValueError:
                continue
    return None


def classify(
    run: Mapping[str, Any],
    last_output_at: float | None,
    agent_status: str | None,
    now: float,
    slow: int,
    stall: int,
) -> str:
    status = str(run.get("status") or "")
    if status != "running":
        return "healthy"

    if run.get("finishedAt"):
        return "lost"
    if str(run.get("issueStatus") or "") in ("done", "cancelled", "blocked"):
        return "lost"
    if agent_status in ("paused", "terminated"):
        return "lost"

    silence = run.get("outputSilence") or {}
    level = str(silence.get("level") or "")
    progress = last_output_at if last_output_at is not None else _progress_at(run)

    if progress is None:
        return "unknown"

    age = now - progress
    if age >= stall:
        if level in ABNORMAL:
            return "suspected_stalled"
        if run.get("processPid") or silence.get("lastOutputAt"):
            return "slow"
        return "unknown"
    if age >= slow:
        return "slow"
    return "healthy"


class HealthMonitor:
    def __init__(self, cfg: config.Config, store, pc, clock: Callable[[], float] | None = None,
                 log: Callable[..., Any] = print) -> None:
        self.cfg = cfg
        self.store = store
        self.pc = pc
        self._clock = clock or (lambda: config.now(cfg))
        self.log = log

    def tick(self, now: float | None = None) -> int:
        now = self._clock() if now is None else now
        agents = {str(a["id"]): a for a in self.pc.agents()}
        emitted = 0
        for live in self.pc.live_runs():
            run_id = str(live.get("id") or "")
            if not run_id or str(live.get("status")) != "running":
                continue
            run = self.pc.run(run_id)
            agent = agents.get(str(run.get("agentId") or ""))
            state = classify(
                run,
                _progress_at(run),
                str(agent.get("status")) if agent else None,
                now,
                self.cfg.slow_seconds,
                self.cfg.stall_seconds,
            )
            emitted += int(self._apply(run_id, state, run, now))
        return emitted

    def _apply(self, run_id: str, state: str, run: Mapping[str, Any], now: float) -> bool:
        row = self.store.run_health(run_id)
        previous = (row or {}).get("state")
        if row is None:
            self.store.set_run_health(run_id, state, now, None, 0, now)
            row = self.store.run_health(run_id)

        if state == "healthy":
            if previous and previous != "healthy":
                self.store.set_run_health(run_id, "healthy", now, None, 0, now)
                return self._emit(run_id, run, events.HEALTH_RECOVERED, now)
            return False

        if state not in ("slow", "suspected_stalled", "lost"):
            return False

        last_notified = (row or {}).get("last_notified_at")
        due = last_notified is None or now - float(last_notified) >= self.cfg.health_reminder_seconds
        first = previous != state
        if first or due:
            self.store.set_run_health(run_id, state, now, now, int((row or {}).get("notify_count") or 0) + 1, now)
            kind = {
                "slow": events.HEALTH_SLOW,
                "suspected_stalled": events.HEALTH_STALLED,
                "lost": events.HEALTH_LOST,
            }[state]
            return self._emit(run_id, run, kind, now)
        self.store.set_run_health(run_id, state, now, last_notified, int((row or {}).get("notify_count") or 0), now)
        return False

    def _emit(self, run_id: str, run: Mapping[str, Any], event_type: str, now: float) -> bool:
        bucket = int(now // self.cfg.health_reminder_seconds)
        event = events.Event(
            schema_version=events.SCHEMA_VERSION,
            event_id=events.health_event_id(run_id, event_type, bucket),
            event_type=event_type,
            source="opc",
            company_id="",
            project_id=None,
            issue_id=run.get("issueId"),
            issue_identifier=None,
            run_id=run_id,
            status=str(run.get("status") or ""),
            occurred_at=config.iso(now),
            observed_at=config.iso(now),
            artifact_url=None,
            origin_channel_id=None,
            origin_event_id=None,
            correlation_id=f"{run_id}-{event_type.rsplit('.', 1)[-1]}",
            track="unknown",
        )
        return bool(self.store.enqueue_event(event, now))
