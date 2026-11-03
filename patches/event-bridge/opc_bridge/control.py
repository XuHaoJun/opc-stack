"""Owner-signed control authorization.

A mutation (force stop, pause, allocation, mandate grant/revoke) is authorized
only by an owner-authored Buzz message in the control channel. The bridge
verifies, in this order: the configured operator exists, the event is in the
channel, the author is the operator, the message is fresh, its text is the
command being executed, and this event id has not been used before.

Hermes holds no secret that can forge this: the signature is the operator's.
The one-time-use table is what stops a valid command from being replayed by a
retry loop or a malicious caller.
"""

from __future__ import annotations

import secrets
import uuid
from typing import Any

from . import buzz as buzz_mod
from . import config, policy


class AuthError(Exception):
    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"operator authorization failed: {reason}")


class PolicyError(Exception):
    pass


def _normalize(text: str) -> str:
    return " ".join(str(text or "").split())


class OperatorAuth:
    def __init__(self, cfg: config.Config, buzz_client: buzz_mod.Buzz, store, channel_id: str, clock=None) -> None:
        self.cfg = cfg
        self.buzz = buzz_client
        self.store = store
        self.channel_id = channel_id
        self._clock = clock or (lambda: config.now(cfg))

    def verify(self, command: str, event_id: str, now: float | None = None) -> dict:
        now = self._clock() if now is None else now
        if not self.cfg.operator_pubkey:
            raise AuthError("missing")
        if not event_id:
            raise AuthError("missing")

        # Scan wider than the freshness window so a stale command is reported as
        # stale (a diagnosable refusal) instead of "not found".
        since = int(now - 2 * self.cfg.command_max_age_seconds) - 60
        messages = self.buzz.messages(self.channel_id, since=since, limit=200)
        message = next((m for m in messages if str(m.get("id")) == event_id), None)
        if message is None:
            raise AuthError("not_found")

        author = str(message.get("pubkey") or "").lower()
        if author != self.cfg.operator_pubkey.lower():
            raise AuthError("wrong_author")

        created_at = float(message.get("created_at") or 0)
        if now - created_at > self.cfg.command_max_age_seconds:
            raise AuthError("stale")

        if not _normalize(message.get("content")).startswith(_normalize(command)):
            raise AuthError("command_mismatch")

        if self.store.auth_used(event_id):
            raise AuthError("replayed")

        action = _normalize(command).split(" ")[1] if len(_normalize(command).split(" ")) > 1 else "opc"
        self.store.use_auth(event_id, config.iso(now), action)
        return message


# ── mutations ────────────────────────────────────────────────────────────
def grant_mandate(store, body: dict, actor: str, source_event_id: str | None, now_iso: str) -> dict:
    scope_kind = str(body.get("scope_kind") or "track")
    scope_id = str(body.get("scope_id") or body.get("track") or "")
    if scope_kind not in ("project", "track") or not scope_id:
        raise PolicyError("scope_kind must be project|track with a scope_id")
    track = str(body.get("track") or ("lab" if scope_id == "lab" else "core"))
    style = str(body.get("style") or "blueprint")
    if style not in ("blueprint", "exploration"):
        raise PolicyError("style must be blueprint|exploration")

    row = {
        "id": str(uuid.uuid4()),
        "scope_kind": scope_kind,
        "scope_id": scope_id,
        "style": style,
        "track": track,
        "allowed_json": _json_list(body.get("allowed")),
        "restricted_json": _json_list(body.get("restricted")),
        "followups_allowed": 1 if body.get("followups_allowed") else 0,
        "max_followups_per_day": body.get("max_followups_per_day"),
        "review_policy": str(body.get("review_policy") or "hermes_report"),
        "created_by": actor,
        "source_event_id": source_event_id,
        "created_at": now_iso,
        "expires_at": body.get("expires_at"),
        "reason": str(body.get("reason") or ""),
    }
    store.insert_mandate(row)
    store.audit(actor, "mandate_granted", row["id"], {"scope": f"{scope_kind}:{scope_id}"}, source_event_id)
    return row


def revoke_mandate(store, mandate_id: str, actor: str, source_event_id: str | None, now_iso: str) -> dict:
    if store.get_mandate(mandate_id) is None:
        raise PolicyError("no such mandate")
    changed = store.revoke_mandate(mandate_id, now_iso, actor)
    store.audit(actor, "mandate_revoked", mandate_id, {"changed": changed}, source_event_id)
    return {"id": mandate_id, "revoked": bool(changed)}


def set_override(store, body: dict, actor: str, source_event_id: str | None, now_iso: str) -> dict:
    scope_kind = str(body.get("scope_kind") or "track")
    scope_id = str(body.get("scope_id") or "")
    key = str(body.get("key") or "")
    if scope_kind not in ("company", "track", "project") or not scope_id or not key:
        raise PolicyError("scope_kind, scope_id and key are required")
    if key not in policy.DEFAULTS and key not in policy.HARD_RULES:
        raise PolicyError(f"unknown policy key {key}")
    if key in policy.HARD_RULES:
        raise PolicyError("hard rules cannot be modified")

    import json

    row = {
        "id": str(uuid.uuid4()),
        "scope_kind": scope_kind,
        "scope_id": scope_id,
        "key": key,
        "value_json": json.dumps(body.get("value")),
        "priority": policy.PRIORITY["operator"],
        "created_by": actor,
        "reason": str(body.get("reason") or ""),
        "source_event_id": source_event_id,
        "created_at": now_iso,
        "expires_at": body.get("expires_at"),
    }
    store.insert_policy(row)
    store.audit(actor, "policy_override", row["id"], {"key": key, "value": body.get("value")}, source_event_id)
    return row


def _json_list(value: Any) -> str:
    import json

    return json.dumps(list(value or []))


# ── tracks, allocation and pause ─────────────────────────────────────────
class ForceStopError(Exception):
    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"force stop failed: {reason}")


def resolve_track_agents(pc, selectors: tuple[str, ...]) -> list[dict]:
    """Exact selectors only (`role:engineer`, `name:Prototyper`).

    Zero or multiple matches is a policy error: guessing which agent belongs to
    a track is how a lock ends up protecting the wrong workers.
    """
    agents = pc.agents()
    matched: list[dict] = []
    for selector in selectors:
        kind, _, value = selector.partition(":")
        if kind not in ("role", "name") or not value:
            raise PolicyError(f"bad agent selector {selector!r}")
        hits = [a for a in agents if str(a.get(kind)) == value]
        if not hits:
            raise PolicyError(f"no agent matches {selector}")
        if len(hits) > 1:
            raise PolicyError(f"multiple agents match {selector}")
        matched.append(hits[0])
    ids = {str(a["id"]) for a in matched}
    return [a for a in matched if str(a["id"]) in ids]


def slot_plan(core: int, lab: int, budget: int, lab_agents: int) -> dict[str, int]:
    """Slots for a non-zero split. Exact only at zero; this is approximate."""
    if budget <= 0:
        raise PolicyError("slot budget must be positive")
    core_slots = max(1, round(budget * core / 100)) if core > 0 else 0
    lab_slots = budget - core_slots
    per_agent = max(1, lab_slots // lab_agents) if (lab_slots > 0 and lab_agents) else 0
    return {"core": core_slots, "lab_per_agent": per_agent}


def _agent_track_of(agent: dict, core_ids: set[str]) -> str:
    return "core" if str(agent["id"]) in core_ids else "lab"


def _holds(raw) -> set[str]:
    """lifecycleHolds as a set, tolerant of list or JSON-string shapes."""
    import json

    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            raw = [raw]
    return {str(item) for item in (raw or [])}


def _holds_match(recorded: set[str], current: set[str]) -> bool:
    # `manual` is the hold our own pause adds. Compare everything else, so a
    # human's extra hold (or a cleared one) still blocks the resume.
    return recorded == (current - {"manual"})


def _wait_settled(pc, agent_id: str, want_paused: bool, tries: int = 20) -> dict:
    import time

    agent = pc.agent(agent_id)
    for _ in range(tries):
        state = str(agent.get("lifecycleState") or "")
        status = str(agent.get("status") or "")
        if want_paused and (status == "paused" or state == "paused"):
            return agent
        if not want_paused and status in ("idle", "active") and state not in ("pausing", "paused"):
            return agent
        time.sleep(0.25)
        agent = pc.agent(agent_id)
    return agent


def apply_allocation(
    cfg,
    store,
    pc,
    core: int,
    lab: int,
    actor: str,
    source_event_id: str | None,
    now_iso: str,
    adaptive: bool = False,
) -> dict:
    import json

    if not (0 <= core <= 100 and 0 <= lab <= 100) or core + lab != 100:
        raise PolicyError("allocation must be 0..100 and sum to 100")

    priority = policy.PRIORITY["adaptive"] if adaptive else policy.PRIORITY["operator"]
    if adaptive and store.active_policies(now_iso):
        operator_rows = [
            row
            for row in store.active_policies(now_iso)
            if int(row["priority"]) == policy.PRIORITY["operator"]
            and row["key"] in ("allocation.core", "allocation.lab")
        ]
        if operator_rows:
            return {"applied": False, "reason": "operator override wins"}

    for key, value in (("allocation.core", core), ("allocation.lab", lab)):
        store.insert_policy(
            {
                "id": str(uuid.uuid4()),
                "scope_kind": "company",
                "scope_id": cfg.company_id or "default",
                "key": key,
                "value_json": json.dumps(value),
                "priority": priority,
                "created_by": actor,
                "reason": "allocation",
                "source_event_id": source_event_id,
                "created_at": now_iso,
            }
        )

    core_agents = resolve_track_agents(pc, cfg.core_selectors)
    lab_agents = resolve_track_agents(pc, cfg.lab_selectors)
    core_ids = {str(a["id"]) for a in core_agents}
    changed: list[str] = []

    for track, agents, share in (("core", core_agents, core), ("lab", lab_agents, lab)):
        if share == 0:
            for agent in agents:
                if str(agent.get("status")) == "paused":
                    continue
                store.ledger_put(
                    str(agent["id"]), track, str(agent.get("status")),
                    str(agent.get("lifecycleState")), str(agent.get("lifecycleHolds") or []),
                    source_event_id, now_iso,
                )
                pc.patch_agent(str(agent["id"]), {"status": "paused"})
                _wait_settled(pc, str(agent["id"]), want_paused=True)
                changed.append(str(agent["id"]))
            store.set_track_state(track, "paused", "paused", actor, "allocation 0", source_event_id, now_iso)
        else:
            for agent in agents:
                ledger = store.ledger_get(str(agent["id"]))
                if ledger and not ledger.get("released_at") and str(agent.get("status")) == "paused":
                    current_holds = _holds(agent.get("lifecycleHolds"))
                    recorded = _holds(ledger.get("original_holds_json"))
                    if current_holds and not _holds_match(recorded, current_holds):
                        # Someone (a human) changed the holds while we held the
                        # lock. Resuming would silently clear their pause.
                        changed.append(f"refused:{agent['id']}")
                        continue
                    pc.patch_agent(str(agent["id"]), {"status": "idle"})
                    _wait_settled(pc, str(agent["id"]), want_paused=False)
                    store.ledger_release(str(agent["id"]), now_iso)
                    changed.append(str(agent["id"]))
            plan = slot_plan(core, lab, cfg.slot_budget, len(lab_agents))
            slots = plan["core"] if track == "core" else plan["lab_per_agent"]
            for agent in agents:
                metadata = dict(agent.get("metadata") or {})
                metadata["opcBridgeAllocation"] = {"maxConcurrentRuns": slots}
                pc.patch_agent(
                    str(agent["id"]),
                    {
                        "runtimeConfig": {"heartbeat": {"maxConcurrentRuns": slots}},
                        "metadata": metadata,
                    },
                )
            store.set_track_state(track, "running", "running", actor, "allocation", source_event_id, now_iso)

    store.audit(actor, "allocation_applied", f"core={core} lab={lab}", {"changed": changed}, source_event_id)
    return {"applied": True, "core": core, "lab": lab, "changed": changed}


def reconcile_lock(cfg, store, pc, now_iso: str) -> dict:
    """Re-assert the persisted lock after a restart.

    Only agents this service paused and has not released are touched; an agent
    paused by a human stays paused and is never resumed by us.
    """
    result = {"paused": [], "skipped": []}
    for ledger in store.ledger_all():
        if ledger.get("released_at"):
            continue
        agent = pc.agent(str(ledger["agent_id"]))
        if str(agent.get("status")) == "paused":
            result["skipped"].append(str(ledger["agent_id"]))
            continue
        pc.patch_agent(str(ledger["agent_id"]), {"status": "paused"})
        _wait_settled(pc, str(ledger["agent_id"]), want_paused=True)
        result["paused"].append(str(ledger["agent_id"]))
    if result["paused"]:
        store.audit("bridge", "lock_reasserted", None, result)
    return result


_CANCELLABLE = {"queued", "scheduled_retry", "running"}


def force_stop(pc, run_id: str, actor: str, source_event_id: str | None, store, now, tries: int = 30) -> dict:
    """Cancel exactly one run and prove it.

    Nothing else is touched: no other run, no workspace, no agent. A run that
    is already terminal is a refusal, not a silent success.
    """
    import time

    run = pc.run(run_id)
    status = str(run.get("status") or "")
    if not run or status not in _CANCELLABLE:
        raise ForceStopError("not_cancellable" if run else "not_found")

    pc.cancel_run(run_id)

    final = run
    for _ in range(tries):
        final = pc.run(run_id)
        if str(final.get("status")) not in _CANCELLABLE:
            break
        time.sleep(0.5)

    if str(final.get("status")) not in ("cancelled", "interrupted"):
        raise ForceStopError("timeout")

    issue_id = final.get("issueId") or run.get("issueId")
    if issue_id:
        try:
            pc._request(
                "POST",
                f"/api/issues/{issue_id}/comments",
                {"body": f"OPC_CONTROL: force-stop run={run_id} by={actor}"},
            )
        except Exception:
            pass

    store.audit(actor, "force_stop", run_id, {"status": str(final.get("status"))}, source_event_id)
    return {"run_id": run_id, "status": str(final.get("status")), "issue_id": issue_id}
