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
