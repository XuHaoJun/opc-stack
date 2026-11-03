"""Internal HTTP API.

Compose-network only; no published port. `/v1/health` is deliberately open so
the container healthcheck needs no secret — it exposes liveness, the schema
version and which dependency files are missing, never a credential.

Everything else is behind `Authorization: Bearer <OPC_API_KEY_FILE>` and is
authenticated *before* routing: an unknown path answers 401 to a stranger and
404 to a key holder, so the surface is not enumerable without the key.

Route handlers are registered by the tasks that own them (policy, control,
events). A missing handler is a 404 by design, not a stub that pretends to
answer.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse

from . import __version__, config

Handler = Callable[[dict[str, list[str]]], tuple[int, dict[str, Any]]]


class Api:
    def __init__(self, cfg: config.Config, store, routes: dict[str, Handler] | None = None) -> None:
        self.cfg = cfg
        self.store = store
        self.routes: dict[str, Handler] = dict(routes or {})
        self._key: str | None = None

    # ── auth ─────────────────────────────────────────────────────────────
    def api_key(self) -> str:
        if self._key is None:
            try:
                self._key = self.cfg.api_key_path.read_text().strip()
            except OSError:
                self._key = ""
        return self._key

    def _authorized(self, header: str | None) -> bool:
        key = self.api_key()
        if not key or not header:
            return False
        return header == f"Bearer {key}"

    # ── health ───────────────────────────────────────────────────────────
    def health(self) -> dict[str, Any]:
        missing = []
        if not self.api_key():
            missing.append("api_key")
        if not self.cfg.notifier_key_path.exists():
            missing.append("notifier_key")
        if not self.cfg.paperclip_key_path.exists():
            missing.append("paperclip_key")
        return {
            "status": "ok" if not missing else "degraded",
            "version": __version__,
            "schema_version": self.store.schema_version(),
            "missing": missing,
        }

    # ── server ───────────────────────────────────────────────────────────
    def make_server(self, listen: tuple[str, int] | None = None) -> ThreadingHTTPServer:
        host, port = listen or self.cfg.api_listen
        owner = self

        class RequestHandler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self) -> None:  # noqa: N802 (http.server API)
                owner._handle(self, "GET")

            def do_POST(self) -> None:  # noqa: N802
                owner._handle(self, "POST")

            def do_DELETE(self) -> None:  # noqa: N802
                owner._handle(self, "DELETE")

            def log_message(self, fmt: str, *args: Any) -> None:
                return  # the service logs its own operations

        return ThreadingHTTPServer((host, port), RequestHandler)

    def _handle(self, handler: BaseHTTPRequestHandler, method: str) -> None:
        parsed = urlparse(handler.path)
        path = parsed.path.rstrip("/") or "/"
        query = parse_qs(parsed.query)

        if path == "/v1/health" and method == "GET":
            self._respond(handler, 200, self.health())
            return

        if not self._authorized(handler.headers.get("Authorization")):
            self._respond(handler, 401, {"error": "unauthorized"})
            return

        route = self.routes.get(f"{method} {path}")
        if route is None:
            self._respond(handler, 404, {"error": "not found", "path": path})
            return

        try:
            body = self._read_json(handler) if method in ("POST", "DELETE") else {}
            status, payload = route({**query, "__body__": body})  # type: ignore[dict-item]
        except Exception as exc:  # a bad request must not kill the thread
            self._respond(handler, 400, {"error": str(exc)})
            return
        self._respond(handler, status, payload)

    @staticmethod
    def _read_json(handler: BaseHTTPRequestHandler) -> dict:
        length = int(handler.headers.get("Content-Length") or 0)
        if not length:
            return {}
        raw = handler.rfile.read(length)
        try:
            data = json.loads(raw)
        except ValueError:
            return {}
        return data if isinstance(data, dict) else {}

    @staticmethod
    def _respond(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json; charset=utf-8")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)


def serve(api: Api) -> ThreadingHTTPServer:
    server = api.make_server()
    thread = threading.Thread(target=server.serve_forever, name="api", daemon=True)
    thread.start()
    return server
