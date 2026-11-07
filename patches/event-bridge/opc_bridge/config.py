"""Environment -> Config.

Every value has a default: a missing env var is a working service, not a crash
on boot. Empty strings from compose (`${VAR:-}`) mean "unset" for the optional
channel ids, so the resolver does not treat "" as a destination.

The clock lives here too. Health thresholds are time-based and the tests must
not wait thirty minutes, so `OPC_TEST_NOW` pins "now" for the whole process.
It is documented as test-only; nothing in production sets it.
"""

from __future__ import annotations

import os
import time
import datetime as _dt
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping


@dataclass(frozen=True)
class Config:
    # state
    db_path: Path
    state_dir: Path
    # dependencies
    paperclip_api_url: str
    paperclip_key_path: Path
    relay_url: str
    notifier_key_path: Path
    notifier_pub_path: Path
    api_key_path: Path
    public_url: str
    # service
    api_listen: tuple[str, int]
    company_id: str | None
    # polling / delivery
    poll_interval: float
    reconcile_seconds: float
    reconcile_lookback_hours: float
    cutover_lookback_hours: float
    max_attempts: int
    max_age_hours: float
    run_sweep_limit: int
    run_sweep_overlap_seconds: int
    # adaptive allocation (Phase 3)
    adaptive_enabled: bool
    adaptive_interval: float
    adaptive_window_seconds: int
    adaptive_min_runs: int
    adaptive_min_seconds: int
    adaptive_drift_points: int
    adaptive_hold_seconds: int
    # destinations / authorization
    fallback_channel: str | None
    control_channel: str | None
    command_max_age_seconds: int
    operator_pubkey: str
    # tracks / allocation
    core_selectors: tuple[str, ...]
    lab_selectors: tuple[str, ...]
    alloc_core: int
    alloc_lab: int
    slot_budget: int
    # health
    slow_seconds: int
    stall_seconds: int
    terminal_grace_seconds: int
    health_interval: float
    health_reminder_seconds: int
    # tests
    test_now: float | None


def _text(env: Mapping[str, str], key: str, default: str = "") -> str:
    value = env.get(key)
    return default if value is None else value


def _optional(env: Mapping[str, str], key: str) -> str | None:
    value = (env.get(key) or "").strip()
    return value or None


def _int(env: Mapping[str, str], key: str, default: int) -> int:
    raw = (env.get(key) or "").strip()
    return default if not raw else int(raw)


def _float(env: Mapping[str, str], key: str, default: float) -> float:
    raw = (env.get(key) or "").strip()
    return default if not raw else float(raw)


def _bool(env: Mapping[str, str], key: str, default: bool) -> bool:
    raw = (env.get(key) or "").strip().lower()
    if not raw:
        return default
    return raw in ("1", "true", "yes", "on")


def _split(env: Mapping[str, str], key: str, default: tuple[str, ...]) -> tuple[str, ...]:
    raw = env.get(key)
    if raw is None or not raw.strip():
        return default
    return tuple(item.strip() for item in raw.split(",") if item.strip())


def _listen(raw: str) -> tuple[str, int]:
    host, sep, port = raw.rpartition(":")
    if not sep or not host or not port.isdigit():
        raise ValueError(f"OPC_API_LISTEN must be HOST:PORT, got {raw!r}")
    return host, int(port)


def load(env: Mapping[str, str] | None = None) -> Config:
    env = os.environ if env is None else env

    db_path = Path(_text(env, "OPC_DB_PATH", "/var/lib/opc-bridge/bridge.db"))
    test_now = _optional(env, "OPC_TEST_NOW")

    return Config(
        db_path=db_path,
        state_dir=db_path.parent,
        paperclip_api_url=_text(env, "PAPERCLIP_API_URL", "http://paperclip:3100").rstrip("/"),
        paperclip_key_path=Path(_text(env, "PAPERCLIP_API_KEY_FILE", "/keys/paperclip-api.key")),
        relay_url=_text(env, "BUZZ_RELAY_URL", "ws://buzz:3000"),
        notifier_key_path=Path(_text(env, "OPC_NOTIFIER_NSEC", "/keys/paperclip.nsec")),
        notifier_pub_path=Path(_text(env, "OPC_NOTIFIER_PUB", "/keys/paperclip.pub")),
        api_key_path=Path(_text(env, "OPC_API_KEY_FILE", "/keys/opc-control.key")),
        public_url=_text(env, "OPC_PUBLIC_URL", "").rstrip("/"),
        api_listen=_listen(_text(env, "OPC_API_LISTEN", "0.0.0.0:8645")),
        company_id=_optional(env, "PAPERCLIP_COMPANY_ID"),
        poll_interval=_float(env, "OPC_EVENT_POLL_INTERVAL", 7.0),
        reconcile_seconds=_float(env, "OPC_EVENT_RECONCILE_SECONDS", 600.0),
        reconcile_lookback_hours=_float(env, "OPC_EVENT_RECONCILE_LOOKBACK_HOURS", 24.0),
        cutover_lookback_hours=_float(env, "OPC_EVENT_CUTOVER_LOOKBACK_HOURS", 0.0),
        max_attempts=_int(env, "OPC_EVENT_MAX_ATTEMPTS", 12),
        max_age_hours=_float(env, "OPC_EVENT_MAX_AGE_HOURS", 168.0),
        run_sweep_limit=_int(env, "OPC_RUN_SWEEP_LIMIT", 100),
        run_sweep_overlap_seconds=_int(env, "OPC_RUN_SWEEP_OVERLAP_SECONDS", 300),
        adaptive_enabled=_bool(env, "OPC_ADAPTIVE_ENABLED", True),
        adaptive_interval=_float(env, "OPC_ADAPTIVE_INTERVAL", 300.0),
        adaptive_window_seconds=_int(env, "OPC_ADAPTIVE_WINDOW_SECONDS", 3600),
        adaptive_min_runs=_int(env, "OPC_ADAPTIVE_MIN_RUNS", 5),
        adaptive_min_seconds=_int(env, "OPC_ADAPTIVE_MIN_SECONDS", 600),
        adaptive_drift_points=_int(env, "OPC_ADAPTIVE_DRIFT_POINTS", 15),
        adaptive_hold_seconds=_int(env, "OPC_ADAPTIVE_HOLD_SECONDS", 1800),
        fallback_channel=_optional(env, "OPC_EVENT_FALLBACK_CHANNEL"),
        control_channel=_optional(env, "OPC_CONTROL_CHANNEL"),
        command_max_age_seconds=_int(env, "OPC_CONTROL_COMMAND_MAX_AGE_SECONDS", 900),
        operator_pubkey=_text(env, "OPC_OPERATOR_PUBKEY", "").strip().lower(),
        core_selectors=_split(env, "OPC_TRACK_CORE_AGENTS", ("role:engineer",)),
        lab_selectors=_split(env, "OPC_TRACK_LAB_AGENTS", ("name:Prototyper", "name:Scientist")),
        alloc_core=_int(env, "OPC_ALLOC_CORE", 70),
        alloc_lab=_int(env, "OPC_ALLOC_LAB", 30),
        slot_budget=_int(env, "OPC_SLOT_BUDGET", 6),
        slow_seconds=_int(env, "OPC_SLOW_SECONDS", 900),
        stall_seconds=_int(env, "OPC_STALL_SECONDS", 1800),
        terminal_grace_seconds=_int(env, "OPC_TERMINAL_GRACE_SECONDS", 120),
        health_interval=_float(env, "OPC_HEALTH_INTERVAL", 30.0),
        health_reminder_seconds=_int(env, "OPC_HEALTH_REMINDER_SECONDS", 1800),
        test_now=float(test_now) if test_now else None,
    )


def now(cfg: Config) -> float:
    """Unix seconds. `OPC_TEST_NOW` pins it for deterministic threshold tests."""
    return cfg.test_now if cfg.test_now is not None else time.time()


def iso(ts: float) -> str:
    """Unix seconds -> the ISO-8601 form Paperclip uses (millisecond, Z)."""
    return (
        _dt.datetime.fromtimestamp(ts, _dt.timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def parse_iso(value: str) -> float:
    return _dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
