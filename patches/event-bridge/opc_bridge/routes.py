"""HTTP routes: policy reads, mandate/override mutations, event feed.

Mutations are owner-authorized: the body carries `command` and
`authorization_event_id` (the exact Buzz message the owner posted). Reads are
covered by the API key alone. A mutation without a verified command is refused
with 403 and audited — an API key is not authority.
"""

from __future__ import annotations

import json
from typing import Any, Callable

from . import config, control, policy

Handler = Callable[[dict[str, list[str]]], tuple[int, dict[str, Any]]]


def _body(params: dict) -> dict:
    return params.get("__body__") or {}  # type: ignore[return-value]


def _q(params: dict, name: str, default: str = "") -> str:
    values = params.get(name) or []
    return str(values[0]) if values else default


class Routes:
    def __init__(self, cfg: config.Config, store, auth: control.OperatorAuth | None = None,
                 backfill: Callable[[str], int] | None = None,
                 backfill_labels: Callable[[], int] | None = None,
                 paperclip=None) -> None:
        self.cfg = cfg
        self.store = store
        self.auth = auth
        self._paperclip = paperclip
        self._backfill = backfill
        self._backfill_labels = backfill_labels

    # ── reads ────────────────────────────────────────────────────────────
    def effective(self, params: dict) -> tuple[int, dict]:
        project = _q(params, "project_id") or None
        track = _q(params, "track", "lab")
        return 200, policy.effective(self.store, self._company(), project, track, self._now())

    def mandates(self, params: dict) -> tuple[int, dict]:
        rows = self.store.active_mandates(self._now())
        return 200, {"mandates": rows}

    def state(self, params: dict) -> tuple[int, dict]:
        tracks = {
            track: self.store.track_state(track)
            or {"track": track, "desired": "running", "state": "running"}
            for track in ("core", "lab")
        }
        allocation = policy.effective(self.store, self._company(), None, "lab", self._now())
        return 200, {
            "tracks": tracks,
            "allocation": {
                "core": allocation["values"]["allocation.core"],
                "lab": allocation["values"]["allocation.lab"],
            },
        }

    def events(self, params: dict) -> tuple[int, dict]:
        limit = int(_q(params, "limit", "50") or 50)
        rows = self.store.recent_events(limit)
        return 200, {"events": rows}

    # ── mutations (owner-signed) ─────────────────────────────────────────
    def grant(self, params: dict) -> tuple[int, dict]:
        body = _body(params)
        scope_kind = str(body.get("scope_kind") or "track")
        scope_id = str(body.get("scope_id") or body.get("track") or "")
        actor = self._authorize(body, "!opc mandate grant", [f"{scope_kind}={scope_id}"])
        try:
            row = control.grant_mandate(
                self.store, body, actor, body.get("authorization_event_id"), self._now()
            )
        except control.PolicyError as exc:
            return 400, {"error": str(exc)}
        return 201, {"mandate": row}

    def revoke(self, params: dict) -> tuple[int, dict]:
        body = _body(params)
        actor = self._authorize(body, "!opc mandate revoke", [str(body.get("id") or "")])
        try:
            return 200, control.revoke_mandate(
                self.store, str(body.get("id") or ""), actor,
                body.get("authorization_event_id"), self._now(),
            )
        except control.PolicyError as exc:
            return 404, {"error": str(exc)}

    def override(self, params: dict) -> tuple[int, dict]:
        body = _body(params)
        actor = self._authorize(
            body, "!opc override", [str(body.get("scope_id") or ""), str(body.get("key") or "")]
        )
        try:
            row = control.set_override(
                self.store, body, actor, body.get("authorization_event_id"), self._now()
            )
        except control.PolicyError as exc:
            return 400, {"error": str(exc)}
        return 201, {"policy": row}

    def override_revoke(self, params: dict) -> tuple[int, dict]:
        body = _body(params)
        actor = self._authorize(body, "!opc override revoke", [str(body.get("id") or "")])
        policy_id = str(body.get("id") or "")
        changed = self.store.revoke_policy(policy_id, self._now())
        self.store.audit(actor, "policy_override_revoked", policy_id, {"changed": changed})
        return 200, {"id": policy_id, "revoked": bool(changed)}

    def allocation(self, params: dict) -> tuple[int, dict]:
        body = _body(params)
        try:
            core = int(body.get("core", 0))
            lab = int(body.get("lab", 0))
        except (TypeError, ValueError):
            return 400, {"error": "core and lab must be integers"}
        actor = self._authorize(body, "!opc allocate", [f"core={core}", f"lab={lab}"])
        from . import control as control_mod

        try:
            result = control_mod.apply_allocation(
                self.cfg, self.store, self._paperclip, core, lab, actor,
                body.get("authorization_event_id"), self._now(),
                adaptive=bool(body.get("adaptive")),
            )
        except control.PolicyError as exc:
            return 400, {"error": str(exc)}
        return 200, result

    def force_stop(self, params: dict) -> tuple[int, dict]:
        body = _body(params)
        run_id = str(body.get("run_id") or "")
        if not run_id:
            return 400, {"error": "run_id is required"}
        actor = self._authorize(body, "!opc force-stop run", [run_id])
        from . import control as control_mod

        try:
            result = control_mod.force_stop(
                self._paperclip, run_id, actor, body.get("authorization_event_id"),
                self.store, self._now(),
            )
        except control.ForceStopError as exc:
            return (404 if exc.reason == "not_found" else 409), {"error": exc.reason}
        return 200, result

    def backfill(self, params: dict) -> tuple[int, dict]:
        body = _body(params)
        since = str(body.get("since") or "")
        if not since:
            return 400, {"error": "since is required (ISO-8601)"}
        self._authorize(body, "!opc backfill", [since])
        return 200, {"enqueued": self._backfill(since)}

    def backfill_labels(self, params: dict) -> tuple[int, dict]:
        self._authorize(_body(params), "!opc labels backfill", [])
        if self._backfill_labels is None:
            return 503, {"error": "label backfill unavailable"}
        return 200, {"labelled": self._backfill_labels()}

    # ── helpers ──────────────────────────────────────────────────────────
    def _authorize(self, body: dict, verb: str, tokens: list[str]) -> str:
        """The command text is the ROUTE's, never the caller's."""
        if self.auth is None:
            raise _Forbidden("control node not ready")
        event_id = str(body.get("authorization_event_id") or "")
        try:
            self.auth.verify(verb, tokens, event_id)
        except control.AuthError as exc:
            self.store.audit("anonymous", "authorization_refused", event_id, {"reason": exc.reason})
            raise _Forbidden(exc.reason) from None
        return f"operator:{self.cfg.operator_pubkey}"

    def _now(self) -> str:
        return config.iso(config.now(self.cfg))

    def _company(self) -> str:
        # One spelling for the writer and the reader: apply_allocation writes
        # `cfg.company_id or "default"`, so the resolver must match it or the
        # allocation the bridge just applied is invisible to its own policy read.
        return self.cfg.company_id or "default"


class _Forbidden(Exception):
    pass


def build(cfg: config.Config, store, auth=None, backfill=None, backfill_labels=None, paperclip=None) -> dict[str, Handler]:
    routes = Routes(cfg, store, auth, backfill, backfill_labels, paperclip)
    table: dict[str, Handler] = {
        "GET /v1/policy/effective": routes.effective,
        "GET /v1/mandates": routes.mandates,
        "GET /v1/control/state": routes.state,
        "GET /v1/events": routes.events,
        "POST /v1/mandates": routes.grant,
        "POST /v1/mandates/revoke": routes.revoke,
        "POST /v1/control/override": routes.override,
        "POST /v1/control/override/revoke": routes.override_revoke,
        "POST /v1/control/allocation": routes.allocation,
        "POST /v1/control/force-stop": routes.force_stop,
        "POST /v1/control/backfill": routes.backfill,
        "POST /v1/control/backfill-labels": routes.backfill_labels,
    }

    def guarded(handler: Handler) -> Handler:
        def wrapper(params: dict) -> tuple[int, dict]:
            try:
                return handler(params)
            except _Forbidden as exc:
                return 403, {"error": "forbidden", "reason": str(exc)}

        return wrapper

    return {key: guarded(value) for key, value in table.items()}
