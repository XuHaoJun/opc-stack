"""Adaptive allocation: measure the split, then nudge it one slot at a time.

The requirement (original §7.1/§7.3) is *allocation by measured execution*, not
by ticket count: which share of the last hour's agent time went to Core vs Lab,
compared with the intended split, adjusted gradually — and never against an
operator decision.

Rules, all enforced here rather than in a prompt:

* **Where the numbers come from**: `heartbeat-runs` `startedAt`/`finishedAt`,
  clipped to the rolling window, attributed to a track through the agent id.
  Runs without both timestamps, or by an agent in neither track, are ignored.
* **Insufficient evidence is inert**: fewer than `min_runs` finished runs or
  less than `min_seconds` of measured work in the window means "wait", not
  "guess". This is what stops an idle stack from being re-balanced.
* **Drift, not noise**: the gap must exceed `drift_points` for the whole
  `hold_seconds` before anything moves, and one cycle moves one step
  (`round(100 / slot_budget)` points) at most.
* **Never a lock**: adaptive steps that would take either share to 0 are
  refused. Only an operator command can pause a track.
* **Operator override wins**: if any priority-20 allocation row exists, adaptive
  does nothing and forgets its drift timer.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any, Callable, Mapping

from . import config


@dataclass(frozen=True)
class Measurement:
    core_share: float | None
    lab_share: float | None
    total_seconds: float
    runs: int
    reason: str

    @property
    def sufficient(self) -> bool:
        return self.core_share is not None

    def as_dict(self) -> dict[str, Any]:
        return {
            "core_share": None if self.core_share is None else round(self.core_share, 1),
            "lab_share": None if self.lab_share is None else round(self.lab_share, 1),
            "total_seconds": round(self.total_seconds, 1),
            "runs": self.runs,
            "sufficient": self.sufficient,
            "reason": self.reason,
        }


def measure(
    runs: list[Mapping[str, Any]],
    agent_track: Mapping[str, str],
    now: float,
    window_seconds: int,
    min_runs: int,
    min_seconds: int,
) -> Measurement:
    start = now - window_seconds
    totals = {"core": 0.0, "lab": 0.0}
    counted = 0

    for run in runs:
        track = agent_track.get(str(run.get("agentId") or ""))
        if track not in totals:
            continue
        try:
            began = config.parse_iso(str(run.get("startedAt") or ""))
            ended = config.parse_iso(str(run.get("finishedAt") or ""))
        except ValueError:
            continue
        if ended <= start or began >= now:
            continue
        overlap = min(ended, now) - max(began, start)
        if overlap <= 0:
            continue
        totals[track] += overlap
        counted += 1

    total = totals["core"] + totals["lab"]
    if counted < min_runs or total < min_seconds:
        return Measurement(None, None, total, counted, "insufficient samples")
    return Measurement(
        totals["core"] / total * 100.0,
        totals["lab"] / total * 100.0,
        total,
        counted,
        "measured",
    )


def decide(
    current_core: int, measured_core: float, drift_points: int, step: int
) -> tuple[int, int] | None:
    """One-slot nudge toward the measured split, or None.

    Returns `None` when the drift is inside tolerance or when the nudge would
    take a share to zero (adaptive must never create a hard lock).
    """
    gap = measured_core - current_core
    if abs(gap) <= drift_points:
        return None
    move = -step if gap > 0 else step
    new_core = current_core + move
    new_lab = 100 - new_core
    if new_core <= 0 or new_lab <= 0:
        return None
    return new_core, new_lab


class AdaptiveController:
    def __init__(
        self,
        cfg: config.Config,
        store,
        pc,
        clock: Callable[[], float] | None = None,
        log: Callable[..., Any] = print,
    ) -> None:
        self.cfg = cfg
        self.store = store
        self.pc = pc
        self._clock = clock or (lambda: config.now(cfg))
        self.log = log

    # ── state ────────────────────────────────────────────────────────────
    def state(self) -> dict[str, Any]:
        raw = self.store.get_meta("adaptive_state")
        try:
            return json.loads(raw) if raw else {}
        except ValueError:
            return {}

    def _write_state(self, state: Mapping[str, Any]) -> None:
        self.store.set_meta("adaptive_state", json.dumps(state, ensure_ascii=False))

    # ── loop body ────────────────────────────────────────────────────────
    def tick(self, now: float | None = None) -> int:
        if not self.cfg.adaptive_enabled:
            return 0
        now = self._clock() if now is None else now
        now_iso = config.iso(now)

        previous = self.state()
        # Only the drift timer carries across ticks; every other key is derived,
        # so a stale "skipped" from an earlier tick cannot linger in the state
        # the operator reads.
        state: dict[str, Any] = {
            key: previous[key]
            for key in ("drift_since", "drift_direction")
            if key in previous
        }

        operator = [
            row
            for row in self.store.active_policies(now_iso)
            if int(row["priority"]) == 20 and row["key"].startswith("allocation.")
        ]
        if operator:
            self._write_state({"skipped": "operator override", "at": now_iso})
            return 0

        from . import control, policy

        resolved = policy.effective(self.store, self.cfg.company_id or "default", None, "lab", now_iso)
        current_core = int(resolved["values"].get("allocation.core", 70))
        current_lab = int(resolved["values"].get("allocation.lab", 100 - current_core))

        core_agents = control.resolve_track_agents(self.pc, self.cfg.core_selectors)
        lab_agents = control.resolve_track_agents(self.pc, self.cfg.lab_selectors)
        agent_track = {str(a["id"]): "core" for a in core_agents}
        agent_track.update({str(a["id"]): "lab" for a in lab_agents})

        runs = self.pc.heartbeat_runs(limit=self.cfg.run_sweep_limit)
        measurement = measure(
            runs,
            agent_track,
            now,
            self.cfg.adaptive_window_seconds,
            self.cfg.adaptive_min_runs,
            self.cfg.adaptive_min_seconds,
        )

        state["measured"] = measurement.as_dict()
        state["at"] = now_iso

        if not measurement.sufficient:
            state.pop("drift_since", None)
            state["decision"] = "wait"
            self._write_state(state)
            return 0

        assert measurement.core_share is not None
        step = max(1, round(100 / max(1, self.cfg.slot_budget)))
        target = decide(current_core, measurement.core_share, self.cfg.adaptive_drift_points, step)
        if target is None:
            state.pop("drift_since", None)
            state["decision"] = "within tolerance"
            self._write_state(state)
            return 0

        direction = "core>measured" if measurement.core_share < current_core else "core<measured"
        if state.get("drift_direction") != direction:
            state["drift_direction"] = direction
            state["drift_since"] = now_iso
            state["decision"] = "drift detected"
            self._write_state(state)
            return 0

        held = now - config.parse_iso(str(state.get("drift_since") or now_iso))
        if held < self.cfg.adaptive_hold_seconds:
            state["decision"] = f"drifting {int(held)}s/{self.cfg.adaptive_hold_seconds}s"
            self._write_state(state)
            return 0

        new_core, new_lab = target
        result = control.apply_allocation(
            self.cfg, self.store, self.pc, new_core, new_lab, "bridge:adaptive",
            None, now_iso, adaptive=True,
        )
        state.pop("drift_since", None)
        state.pop("drift_direction", None)
        state["decision"] = f"adjusted {current_core}/{current_lab} -> {new_core}/{new_lab}"
        state["last_adjustment"] = {"at": now_iso, "from": [current_core, current_lab], "to": [new_core, new_lab]}
        self._write_state(state)
        self.store.audit(
            "bridge:adaptive",
            "allocation_adaptive",
            f"core={new_core} lab={new_lab}",
            {"measured_core": measurement.core_share, "applied": result.get("applied")},
        )
        self.log(f"[adaptive] {current_core}/{current_lab} -> {new_core}/{new_lab} (measured {measurement.core_share:.1f}% core)")
        return 1 if result.get("applied") else 0
