"""Policy precedence resolver.

Order (lower number wins, a lower-priority value can never override a higher):

  10 hard safety rules   — code only; no grant can enable them
  20 operator override   — owner-signed command / ops CLI
  30 execution mandate   — owner-signed grant
  40 adaptive            — the bridge (allocation only)
  50 defaults            — code

Within one priority: project scope beats track beats company, then the newest
grant, then the **more restrictive** value. The restrictive tie-break is not
configurable: a resolver that can silently widen a mandate is a bug.

`effective()` returns provenance for every key so the agent can explain a
refusal, and so a test can prove which row won.
"""

from __future__ import annotations

import json
from typing import Any

PRIORITY = {"hard": 10, "operator": 20, "mandate": 30, "adaptive": 40, "default": 50}
_SCOPE_RANK = {"company": 1, "track": 2, "project": 3}

HARD_RULES = {
    "production_deploy": False,
    "merge_main": False,
    "publish_public": False,
    "spend_money": False,
    "destructive_delete": False,
    "grant_access": False,
}

DEFAULTS = {
    "allocation.core": 70,
    "allocation.lab": 30,
    "followups.allowed": False,
    "style": "blueprint",
    "review.policy": "hermes_report",
    "track_locked": False,
    "max_followups_per_day": 0,
}


def _restrictive(left: Any, right: Any) -> Any:
    """The value that grants less."""
    if isinstance(left, bool) and isinstance(right, bool):
        return left and right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return min(left, right)
    if isinstance(left, list) and isinstance(right, list):
        return [item for item in left if item in right]
    if left == "blueprint" or right == "blueprint":
        return "blueprint"
    return left


def _candidate(
    key: str,
    value: Any,
    priority: int,
    scope: str,
    created_at: str,
    source: str,
    row_id: str | None = None,
) -> dict:
    return {
        "key": key,
        "value": value,
        "priority": priority,
        "scope": scope,
        "created_at": created_at,
        "source": source,
        "row_id": row_id,
    }


def _pick(candidates: list[dict]) -> dict:
    candidates = sorted(
        candidates,
        key=lambda c: (c["priority"], -_SCOPE_RANK.get(c["scope"], 0)),
    )
    best_priority = candidates[0]["priority"]
    same = [c for c in candidates if c["priority"] == best_priority]

    best_rank = max(_SCOPE_RANK.get(c["scope"], 0) for c in same)
    same = [c for c in same if _SCOPE_RANK.get(c["scope"], 0) == best_rank]

    newest = max(c["created_at"] for c in same)
    same = [c for c in same if c["created_at"] == newest]

    winner = same[0]
    for candidate in same[1:]:
        winner = {**winner, "value": _restrictive(winner["value"], candidate["value"])}
    return winner


def mandate_keys(mandate: dict) -> dict[str, Any]:
    allowed = json.loads(mandate.get("allowed_json") or "[]")
    restricted = json.loads(mandate.get("restricted_json") or "[]")
    return {
        "followups.allowed": bool(mandate.get("followups_allowed")),
        "style": mandate.get("style") or "blueprint",
        "review.policy": mandate.get("review_policy") or "hermes_report",
        "max_followups_per_day": int(mandate.get("max_followups_per_day") or 0),
        "actions.allowed": allowed,
        "actions.restricted": restricted,
    }


def effective(store, company_id: str, project_id: str | None, track: str, now_iso: str) -> dict:
    candidates: dict[str, list[dict]] = {}

    def add(key: str, value: Any, priority: int, scope: str, created_at: str, source: str, row_id=None):
        candidates.setdefault(key, []).append(
            _candidate(key, value, priority, scope, created_at, source, row_id)
        )

    for key, value in DEFAULTS.items():
        add(key, value, PRIORITY["default"], "company", "", "default")
    for action, allowed in HARD_RULES.items():
        add(f"actions.{action}", allowed, PRIORITY["hard"], "company", "", "hard")

    for row in store.active_policies(now_iso):
        if row["scope_kind"] == "company" and row["scope_id"] != company_id:
            continue
        if row["scope_kind"] == "project" and row["scope_id"] != project_id:
            continue
        if row["scope_kind"] == "track" and row["scope_id"] != track:
            continue
        add(
            row["key"],
            json.loads(row["value_json"]),
            int(row["priority"]),
            row["scope_kind"],
            row["created_at"],
            row["created_by"],
            row["id"],
        )

    for mandate in store.active_mandates(now_iso):
        if mandate["scope_kind"] == "project" and mandate["scope_id"] != project_id:
            continue
        if mandate["scope_kind"] == "track" and mandate["scope_id"] != track:
            continue
        if mandate["scope_kind"] not in ("project", "track"):
            continue
        for key, value in mandate_keys(mandate).items():
            if key in ("actions.allowed", "actions.restricted"):
                continue
            add(
                key,
                value,
                PRIORITY["mandate"],
                mandate["scope_kind"],
                mandate["created_at"],
                f"mandate:{mandate['id']}",
                mandate["id"],
            )

    winner: dict[str, dict] = {key: _pick(rows) for key, rows in candidates.items()}
    values = {key: row["value"] for key, row in winner.items()}
    provenance = {
        key: {
            "priority": row["priority"],
            "source": row["source"],
            "scope": row["scope"],
            "row_id": row["row_id"],
        }
        for key, row in winner.items()
    }
    return {"values": values, "provenance": provenance}


def check(store, company_id: str, project_id: str | None, track: str, action: str, now_iso: str) -> tuple[bool, str]:
    resolved = effective(store, company_id, project_id, track, now_iso)
    values = resolved["values"]

    if action in HARD_RULES:
        return False, "hard rule"

    mandates = [
        m
        for m in store.active_mandates(now_iso)
        if (m["scope_kind"] == "project" and m["scope_id"] == project_id)
        or (m["scope_kind"] == "track" and m["scope_id"] == track)
    ]
    restricted: list[str] = []
    allowed_sets: list[list[str]] = []
    for mandate in mandates:
        parsed = mandate_keys(mandate)
        restricted.extend(parsed["actions.restricted"])
        if parsed["actions.allowed"]:
            allowed_sets.append(parsed["actions.allowed"])

    if action in restricted:
        return False, "restricted by mandate"
    if allowed_sets and not any(action in allowed for allowed in allowed_sets):
        return False, "not allowed by any active mandate"
    if values.get("track_locked") is True:
        return False, "track is locked by the operator"
    return True, "allowed"
