#!/usr/bin/env python3
"""Small authenticated Paperclip API fixture for workspace-routing tests.

The fixture deliberately keeps persistence and HTTP handling boring: tests own the
state file, each request reads the current in-memory state, and future mutating
handlers can call save_state() for an atomic replacement.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import signal
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit


DEFAULT_ENGINEER = {
    "id": "00000000-0000-4000-8000-000000000010",
    "name": "Fullstack Engineer",
    "role": "engineer",
    "status": "idle",
    "runtimeConfig": {"heartbeat": {"maxConcurrentRuns": 4}},
    "metadata": {"opcManagedDefaults": {"fullstackMaxConcurrentRuns": 4}},
}

DEFAULT_STATE = {
    "experimental": {"enableIsolatedWorkspaces": False},
    "company": {
        "id": "00000000-0000-4000-8000-000000000001",
        "name": "Fixture",
    },
    "agents": [DEFAULT_ENGINEER],
    "projects": [],
    "issues": [],
}
STATE_PATH = Path(os.environ.get("PAPERCLIP_FIXTURE_STATE", "")) if os.environ.get("PAPERCLIP_FIXTURE_STATE") else None
LOCK = threading.RLock()
STATE: dict = {}


def initial_state() -> dict:
    return json.loads(json.dumps(DEFAULT_STATE))


def save_state() -> None:
    """Atomically persist STATE beside the caller-owned state file."""
    if STATE_PATH is None:
        return
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        prefix=f".{STATE_PATH.name}.", suffix=".tmp", dir=STATE_PATH.parent
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(STATE, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, STATE_PATH)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def load_state() -> None:
    global STATE
    with LOCK:
        if STATE_PATH is None or not STATE_PATH.exists():
            STATE = initial_state()
            if STATE_PATH is not None:
                save_state()
            return
        with STATE_PATH.open("r", encoding="utf-8") as stream:
            loaded = json.load(stream)
        if not isinstance(loaded, dict):
            raise ValueError("fixture state must be a JSON object")
        STATE = loaded
        # Keep newly introduced top-level collections available to later handlers
        # without rewriting the caller's existing fixture data unnecessarily.
        for key, value in DEFAULT_STATE.items():
            STATE.setdefault(key, json.loads(json.dumps(value)))


def json_bytes(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "paperclip-fixture/1"

    def log_message(self, format: str, *args: object) -> None:
        # Never include headers or request bodies: credentials must not reach logs.
        sys.stderr.write(f"{self.command} {urlsplit(self.path).path}\n")
        sys.stderr.flush()

    def _send_json(self, status: int, value: object) -> None:
        body = json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        return self.headers.get("Authorization", "") == "Bearer fixture-key"

    def _request_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        value = json.loads(body or b"{}")
        if not isinstance(value, dict):
            raise ValueError("request body must be an object")
        return value
    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return
        path = [unquote(part) for part in urlsplit(self.path).path.split("/") if part]
        if not path or path[0] != "api":
            self._send_json(404, {"error": "not found"})
            return
        try:
            payload = self._request_json()
        except (ValueError, json.JSONDecodeError):
            self._send_json(400, {"error": "invalid JSON object"})
            return
        with LOCK:
            if len(path) == 4 and path[:2] == ["api", "companies"] and path[3] == "projects":
                company_id = path[2]
                if company_id != str(STATE.get("company", {}).get("id", "")):
                    self._send_json(404, {"error": "company not found"})
                    return
                project = dict(payload)
                project["id"] = self._next_id("project-", "projects")
                workspace_payload = project.pop("workspace", None)
                workspaces = project.get("workspaces")
                if not isinstance(workspaces, list):
                    workspaces = []
                else:
                    workspaces = [dict(workspace) for workspace in workspaces]
                if isinstance(workspace_payload, dict):
                    workspace = dict(workspace_payload)
                    workspace["id"] = self._next_workspace_id()
                    workspaces.append(workspace)
                    project["primaryWorkspace"] = dict(workspace)
                project["workspaces"] = workspaces
                if "primaryWorkspace" not in project:
                    primary = next(
                        (workspace for workspace in workspaces if workspace.get("isPrimary") is True),
                        None,
                    )
                    if primary is not None:
                        project["primaryWorkspace"] = dict(primary)
                STATE.setdefault("projects", []).append(project)
                save_state()
                self._send_json(201, project)
                return
            if len(path) == 4 and path[:2] == ["api", "companies"] and path[3] == "issues":
                company_id = path[2]
                if company_id != str(STATE.get("company", {}).get("id", "")):
                    self._send_json(404, {"error": "company not found"})
                    return
                idempotency_key = payload.get("idempotencyKey")
                if isinstance(idempotency_key, str) and idempotency_key:
                    replay = next(
                        (
                            existing
                            for existing in STATE.get("issues", [])
                            if isinstance(existing, dict)
                            and existing.get("idempotencyKey") == idempotency_key
                        ),
                        None,
                    )
                    if replay is not None:
                        self._send_json(200, replay)
                        return
                if payload.get("allowDuplicate") is False:
                    title = " ".join(str(payload.get("title", "")).split()).lower()
                    parent_id = payload.get("parentId")
                    now = datetime.datetime.now(datetime.timezone.utc)

                    def recent_open_same_scope(existing: dict) -> bool:
                        if not isinstance(existing, dict):
                            return False
                        if (existing.get("status") or "") in {"done", "cancelled"}:
                            return False
                        if existing.get("hiddenAt") is not None:
                            return False
                        if existing.get("parentId") != parent_id:
                            return False
                        if " ".join(str(existing.get("title", "")).split()).lower() != title:
                            return False
                        created_at = existing.get("createdAt")
                        if not isinstance(created_at, str):
                            return False
                        try:
                            parsed = datetime.datetime.fromisoformat(created_at.replace("Z", "+00:00"))
                        except ValueError:
                            return False
                        if parsed.tzinfo is None:
                            parsed = parsed.replace(tzinfo=datetime.timezone.utc)
                        return now - parsed <= datetime.timedelta(hours=48)

                    replay = next(
                        (existing for existing in STATE.get("issues", []) if recent_open_same_scope(existing)),
                        None,
                    )
                    if replay is not None:
                        self._send_json(200, replay)
                        return
                issue = dict(payload)
                settings = issue.get("executionWorkspaceSettings")
                if isinstance(settings, dict) and settings.get("mode") == "reuse_existing":
                    if (
                        not issue.get("executionWorkspaceId")
                        or issue.get("executionWorkspacePreference") != "reuse_existing"
                        or "executionWorkspaceId" in settings
                    ):
                        self._send_json(400, {"error": "reuse_existing requires top-level executionWorkspaceId and executionWorkspacePreference"})
                        return
                issue["id"] = self._next_id("issue-", "issues")
                issue.setdefault("identifier", self._next_identifier())
                issue.setdefault("status", "todo")
                issue.setdefault("createdAt", datetime.datetime.now(datetime.timezone.utc).isoformat())
                STATE.setdefault("issues", []).append(issue)
                save_state()
                self._send_json(201, issue)
                return
            self._send_json(404, {"error": "not found"})

    @staticmethod
    def _deterministic_uuid(base: int, ordinal: int) -> str:
        return f"00000000-0000-4000-8000-{base + ordinal:012x}"

    def _next_id(self, prefix: str, collection: str) -> str:
        base = {"projects": 0x101, "issues": 0x301}[collection]
        existing = {
            str(item.get("id", ""))
            for item in STATE.get(collection, [])
            if isinstance(item, dict)
        }
        ordinal = 1
        while self._deterministic_uuid(base, ordinal) in existing:
            ordinal += 1
        return self._deterministic_uuid(base, ordinal)

    def _next_workspace_id(self) -> str:
        existing = set()
        for project in STATE.get("projects", []):
            if not isinstance(project, dict):
                continue
            workspaces = project.get("workspaces", [])
            if isinstance(workspaces, list):
                existing.update(
                    str(workspace.get("id", ""))
                    for workspace in workspaces
                    if isinstance(workspace, dict)
                )
            primary = project.get("primaryWorkspace")
            if isinstance(primary, dict):
                existing.add(str(primary.get("id", "")))
        ordinal = 1
        while self._deterministic_uuid(0x201, ordinal) in existing:
            ordinal += 1
        return self._deterministic_uuid(0x201, ordinal)

    def _next_identifier(self) -> str:
        values = [
            int(str(issue.get("identifier", ""))[4:])
            for issue in STATE.get("issues", [])
            if isinstance(issue, dict)
            and str(issue.get("identifier", "")).startswith("FIX-")
            and str(issue.get("identifier", ""))[4:].isdigit()
        ]
        return f"FIX-{max(values, default=0) + 1}"

    def _find_project(self, project_id: str) -> dict | None:
        return next(
            (
                project
                for project in STATE.get("projects", [])
                if isinstance(project, dict) and str(project.get("id", "")) == project_id
            ),
            None,
        )


    def do_PATCH(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return
        path = [unquote(part) for part in urlsplit(self.path).path.split("/") if part]
        if not path or path[0] != "api":
            self._send_json(404, {"error": "not found"})
            return
        try:
            update = self._request_json()
        except (ValueError, json.JSONDecodeError):
            self._send_json(400, {"error": "invalid JSON object"})
            return
        with LOCK:
            if path == ["api", "instance", "settings", "experimental"]:
                experimental = STATE.setdefault("experimental", {})
                experimental.update(update)
                save_state()
                self._send_json(200, experimental)
            elif len(path) == 3 and path[:2] == ["api", "agents"]:
                for agent in STATE.get("agents", []):
                    if str(agent.get("id", "")) == path[2]:
                        agent.update(update)
                        save_state()
                        self._send_json(200, agent)
                        return
                self._send_json(404, {"error": "agent not found"})
            elif len(path) == 3 and path[:2] == ["api", "projects"]:
                project = self._find_project(path[2])
                if project is None:
                    self._send_json(404, {"error": "project not found"})
                    return
                project.update(update)
                save_state()
                self._send_json(200, project)
            elif (
                len(path) == 5
                and path[:2] == ["api", "projects"]
                and path[3] == "workspaces"
            ):
                project = self._find_project(path[2])
                if project is None:
                    self._send_json(404, {"error": "project not found"})
                    return
                workspace = next(
                    (
                        workspace
                        for workspace in project.get("workspaces", [])
                        if isinstance(workspace, dict)
                        and str(workspace.get("id", "")) == path[4]
                    ),
                    None,
                )
                if workspace is None and isinstance(project.get("primaryWorkspace"), dict):
                    primary = project["primaryWorkspace"]
                    if str(primary.get("id", "")) == path[4]:
                        workspace = primary
                if workspace is None:
                    self._send_json(404, {"error": "workspace not found"})
                    return
                workspace.update(update)
                if (
                    isinstance(project.get("primaryWorkspace"), dict)
                    and str(project["primaryWorkspace"].get("id", "")) == path[4]
                ):
                    project["primaryWorkspace"].update(update)
                save_state()
                self._send_json(200, workspace)
            else:
                self._send_json(404, {"error": "not found"})

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        path = [unquote(part) for part in parsed.path.split("/") if part]
        if not path or path[0] != "api":
            self._send_json(404, {"error": "not found"})
            return
        with LOCK:
            if path == ["api", "health"]:
                self._send_json(200, {"status": "ok"})
            elif path == ["api", "companies"]:
                self._send_json(200, [STATE["company"]])
            elif path == ["api", "instance", "settings", "experimental"]:
                self._send_json(200, STATE.get("experimental", {}))
            elif len(path) == 4 and path[:2] == ["api", "companies"] and path[3] == "agents":
                self._company_collection(path[2], "agents")
            elif len(path) == 3 and path[:2] == ["api", "agents"]:
                for agent in STATE.get("agents", []):
                    if str(agent.get("id", "")) == path[2]:
                        self._send_json(200, agent)
                        return
                self._send_json(404, {"error": "agent not found"})
            elif len(path) == 4 and path[:2] == ["api", "companies"] and path[3] == "issues":
                if path[2] != str(STATE.get("company", {}).get("id", "")):
                    self._send_json(404, {"error": "company not found"})
                elif "limit" not in query and "offset" not in query:
                    self._company_collection(path[2], "issues")
                else:
                    try:
                        limit = max(0, int(query.get("limit", ["500"])[0]))
                        offset = max(0, int(query.get("offset", ["0"])[0]))
                    except (TypeError, ValueError):
                        self._send_json(400, {"error": "invalid pagination"})
                    else:
                        issues = STATE.get("issues", [])
                        self._send_json(200, issues[offset : offset + limit])
            elif len(path) == 4 and path[:2] == ["api", "companies"] and path[3] == "projects":
                self._company_collection(path[2], "projects")
            elif len(path) == 3 and path[:2] == ["api", "projects"]:
                self._project(path[2])
            elif len(path) == 3 and path[:2] == ["api", "issues"]:
                for issue in STATE.get("issues", []):
                    if str(issue.get("id", "")) == path[2]:
                        self._send_json(200, issue)
                        return
                self._send_json(404, {"error": "issue not found"})
            elif len(path) == 4 and path[:2] == ["api", "projects"] and path[3] == "workspaces":
                self._project_workspaces(path[2])
            else:
                self._send_json(404, {"error": "not found"})
    def _company_collection(self, company_id: str, key: str) -> None:
        if company_id != str(STATE.get("company", {}).get("id", "")):
            self._send_json(404, {"error": "company not found"})
            return
        self._send_json(200, STATE.get(key, []))

    def _project(self, project_id: str) -> None:
        for project in STATE.get("projects", []):
            if str(project.get("id", "")) == project_id:
                self._send_json(200, project)
                return
        self._send_json(404, {"error": "project not found"})

    def _project_workspaces(self, project_id: str) -> None:
        for project in STATE.get("projects", []):
            if str(project.get("id", "")) == project_id:
                workspaces = project.get("workspaces")
                if workspaces is None and isinstance(project.get("primaryWorkspace"), dict):
                    workspaces = [project["primaryWorkspace"]]
                self._send_json(200, workspaces if isinstance(workspaces, list) else [])
                return
        self._send_json(404, {"error": "project not found"})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", nargs="?", type=int, help="loopback port")
    parser.add_argument("--port", dest="port_option", type=int, help="loopback port")
    return parser.parse_args()


def main() -> int:
    global STATE_PATH
    args = parse_args()
    if STATE_PATH is None and os.environ.get("PAPERCLIP_FIXTURE_STATE"):
        STATE_PATH = Path(os.environ["PAPERCLIP_FIXTURE_STATE"])
    port = args.port_option if args.port_option is not None else args.port
    if port is None:
        port = int(os.environ.get("PAPERCLIP_FIXTURE_PORT", "0"))
    load_state()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write(f"paperclip fixture listening on 127.0.0.1:{server.server_port}\n")
    sys.stderr.flush()

    def stop(_signum: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
