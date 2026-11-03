"""At-least-once delivery through a durable outbox.

The state machine is `pending -> sending -> sent | fallback_sent | failed |
expired`. `sending` is written before the Buzz call and reset to `pending` on
boot, which is what makes a crash between "relay accepted" and "we recorded it"
recoverable: the retry carries the same `event_id`, and the consumer-side gate
drops the duplicate wake.

Destination ladder, first match wins (spec §7): the ticket's origin thread, the
operator's fallback channel, the control channel, else `failed` with
`no_destination`. Nothing is ever dropped silently — a failed row is audited
and visible through the read API.
"""

from __future__ import annotations

import json
from typing import Any, Callable, Mapping

from . import buzz, config, events

MAX_BACKOFF_SECONDS = 300
BASE_BACKOFF_SECONDS = 5


class Deliverer:
    def __init__(
        self,
        cfg: config.Config,
        store,
        buzz_client: buzz.Buzz,
        clock: Callable[[], float] | None = None,
        log: Callable[..., Any] = print,
    ) -> None:
        self.cfg = cfg
        self.store = store
        self.buzz = buzz_client
        self._clock = clock or (lambda: config.now(cfg))
        self.log = log

    # ── policy ───────────────────────────────────────────────────────────
    def next_backoff(self, attempts: int) -> float:
        return float(min(MAX_BACKOFF_SECONDS, BASE_BACKOFF_SECONDS * (2 ** max(0, attempts))))

    def destination(self, payload: Mapping[str, Any]) -> str | None:
        return (
            payload.get("origin_channel_id")
            or self.cfg.fallback_channel
            or self.store.get_meta("control_channel")
        )

    # ── loop ─────────────────────────────────────────────────────────────
    def run_once(self) -> int:
        now = self._clock()
        delivered = 0
        for row in self.store.claim_due(now):
            payload = row["payload"]
            if isinstance(payload, str):
                payload = json.loads(payload)
            event = events.Event.from_dict(payload)
            delivered += int(self._deliver(row, event, now))
        return delivered

    def _deliver(self, row: Mapping[str, Any], event: events.Event, now: float) -> bool:
        if self._expired(event, now):
            self.store.mark_expired(event.event_id, now)
            self.store.audit(
                "bridge", "delivery_expired", event.event_id, {"occurred_at": event.occurred_at}
            )
            self.log(f"[deliver] expired {event.event_id} (occurred {event.occurred_at})")
            return False

        channel = self.destination(event.to_dict())
        if not channel:
            self._fail(event, "no_destination")
            return False

        content = events.render_message(event, {}, self.cfg.public_url)
        try:
            result = self.buzz.send(
                channel,
                content,
                reply_to=event.origin_event_id,
                tags=events.event_tags(event),
            )
        except buzz.BuzzError as exc:
            return self._handle_failure(row, event, channel, exc, now)

        self.store.mark_sent(event.event_id, result.event_id, now)
        self.store.audit(
            "bridge",
            "delivery_sent",
            event.event_id,
            {"channel": channel, "buzz_event_id": result.event_id},
        )
        return True

    def _handle_failure(
        self,
        row: Mapping[str, Any],
        event: events.Event,
        channel: str,
        exc: buzz.BuzzError,
        now: float,
    ) -> bool:
        if exc.kind == "not_member":
            return self._fallback(event, channel, now)

        attempts = int(row.get("attempts") or 0)
        if attempts + 1 >= self.cfg.max_attempts:
            self._fail(event, f"{exc.kind}: {exc.message}")
            self._alert(event, exc)
            return False

        self.store.reschedule(
            event.event_id, now + self.next_backoff(attempts), f"{exc.kind}: {exc.message}", now
        )
        return False

    def _fallback(self, event: events.Event, failed_channel: str, now: float) -> bool:
        fallback = self.cfg.fallback_channel or self.store.get_meta("control_channel")
        if not fallback or fallback == failed_channel:
            self._fail(event, "not_member: no fallback destination")
            return False

        try:
            result = self.buzz.send(
                fallback,
                events.render_message(event, {}, self.cfg.public_url),
                reply_to=None,
                tags=events.event_tags(event),
            )
        except buzz.BuzzError as exc:
            self._fail(event, f"not_member + fallback failed: {exc.kind}")
            return False

        self.store.mark_fallback(event.event_id, result.event_id, now)
        self.store.audit(
            "bridge",
            "delivery_fallback",
            event.event_id,
            {"from": failed_channel, "to": fallback, "buzz_event_id": result.event_id},
        )
        return True

    # ── helpers ──────────────────────────────────────────────────────────
    def _expired(self, event: events.Event, now: float) -> bool:
        try:
            age = now - config.parse_iso(event.occurred_at)
        except (TypeError, ValueError):
            return False
        return age > self.cfg.max_age_hours * 3600.0

    def _fail(self, event: events.Event, reason: str) -> None:
        now = self._clock()
        self.store.mark_failed(event.event_id, reason, now)
        self.store.audit("bridge", "delivery_failed", event.event_id, {"reason": reason})
        self.log(f"[deliver] failed {event.event_id}: {reason}")

    def _alert(self, event: events.Event, exc: buzz.BuzzError) -> None:
        """Best-effort operator alert when an event can never be delivered."""
        fallback = self.cfg.fallback_channel
        if not fallback:
            return
        try:
            self.buzz.send(
                fallback,
                f"⚠️ 事件投遞失敗 · {event.issue_identifier or event.issue_id} · "
                f"{event.event_type} · {event.event_id}\n原因: {exc.kind}",
            )
        except buzz.BuzzError:
            return
