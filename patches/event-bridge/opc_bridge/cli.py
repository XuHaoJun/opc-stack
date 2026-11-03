"""`opc-control` — operator/agent CLI over the bridge's HTTP API.

Reads are key-authenticated. Mutations additionally need the owner-signed Buzz
command that authorizes them (`--command` + `--auth-event`), because the key
alone is not authority.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

from . import config


def _call(cfg: config.Config, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
    try:
        key = cfg.api_key_path.read_text().strip()
    except OSError:
        key = ""
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        f"http://127.0.0.1:{cfg.api_listen[1]}{path}", data=data, method=method
    )
    request.add_header("Authorization", f"Bearer {key}")
    request.add_header("Accept", "application/json")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"{}")


def _auth_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--command", required=True, help="the owner's Buzz command text")
    parser.add_argument("--auth-event", required=True, dest="auth_event", help="that message's event id")


def main(argv: list[str] | None = None) -> int:
    cfg = config.load()
    parser = argparse.ArgumentParser(prog="opc-control")
    sub = parser.add_subparsers(dest="cmd", required=True)

    policy_cmd = sub.add_parser("policy", help="effective policy")
    policy_cmd.add_argument("--project")
    policy_cmd.add_argument("--track", default="lab")

    sub.add_parser("mandates")
    sub.add_parser("state")

    events_cmd = sub.add_parser("events")
    events_cmd.add_argument("--limit", type=int, default=50)

    grant = sub.add_parser("grant", help="grant an execution mandate (owner-signed)")
    grant.add_argument("--track", choices=["core", "lab"])
    grant.add_argument("--project")
    grant.add_argument("--style", choices=["blueprint", "exploration"], default="blueprint")
    grant.add_argument("--followups", action="store_true")
    grant.add_argument("--expires")
    grant.add_argument("--reason", default="")
    _auth_args(grant)

    revoke = sub.add_parser("revoke", help="revoke a mandate (owner-signed)")
    revoke.add_argument("--id", required=True)
    _auth_args(revoke)

    override = sub.add_parser("override", help="set an operator policy override (owner-signed)")
    override.add_argument("--scope-kind", choices=["company", "track", "project"], default="track")
    override.add_argument("--scope-id", required=True)
    override.add_argument("--key", required=True)
    override.add_argument("--value", required=True, help="JSON value, e.g. false or 100")
    override.add_argument("--reason", default="")
    _auth_args(override)

    stop = sub.add_parser("force-stop", help="cancel one run (owner-signed)")
    stop.add_argument("--run", required=True)
    _auth_args(stop)

    backfill = sub.add_parser("backfill", help="deliver history since an ISO timestamp")
    backfill.add_argument("--since", required=True)
    _auth_args(backfill)

    labels = sub.add_parser("backfill-labels", help="label legacy open tickets")
    _auth_args(labels)

    args = parser.parse_args(argv)

    proof = {}
    if getattr(args, "auth_event", None):
        proof = {"command": args.command, "authorization_event_id": args.auth_event}

    if args.cmd == "policy":
        path = f"/v1/policy/effective?track={args.track}"
        if args.project:
            path += f"&project_id={args.project}"
        status, body = _call(cfg, "GET", path)
    elif args.cmd == "mandates":
        status, body = _call(cfg, "GET", "/v1/mandates")
    elif args.cmd == "state":
        status, body = _call(cfg, "GET", "/v1/control/state")
    elif args.cmd == "events":
        status, body = _call(cfg, "GET", f"/v1/events?limit={args.limit}")
    elif args.cmd == "grant":
        payload = {
            "scope_kind": "project" if args.project else "track",
            "scope_id": args.project or args.track,
            "track": args.track or ("lab" if args.project else "core"),
            "style": args.style,
            "followups_allowed": args.followups,
            "expires_at": args.expires,
            "reason": args.reason,
            **proof,
        }
        status, body = _call(cfg, "POST", "/v1/mandates", payload)
    elif args.cmd == "revoke":
        status, body = _call(cfg, "POST", "/v1/mandates/revoke", {"id": args.id, **proof})
    elif args.cmd == "override":
        try:
            value = json.loads(args.value)
        except ValueError:
            value = args.value
        payload = {
            "scope_kind": args.scope_kind,
            "scope_id": args.scope_id,
            "key": args.key,
            "value": value,
            "reason": args.reason,
            **proof,
        }
        status, body = _call(cfg, "POST", "/v1/control/override", payload)
    elif args.cmd == "force-stop":
        status, body = _call(cfg, "POST", "/v1/control/force-stop", {"run_id": args.run, **proof})
    elif args.cmd == "backfill":
        status, body = _call(cfg, "POST", "/v1/control/backfill", {"since": args.since, **proof})
    elif args.cmd == "backfill-labels":
        status, body = _call(cfg, "POST", "/v1/control/backfill-labels", proof)
    else:  # pragma: no cover - argparse enforces the set
        return 2

    print(json.dumps(body, ensure_ascii=False, indent=2))
    return 0 if 200 <= status < 300 else 1


if __name__ == "__main__":
    sys.exit(main())
