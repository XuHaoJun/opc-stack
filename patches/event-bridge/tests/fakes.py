"""Test doubles shared by the unit suite.

A real HTTP server on 127.0.0.1 is used instead of patching urlopen: the client
is thin, and the bugs worth catching (header plumbing, envelope shapes, error
mapping) only show up over a socket.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


class FakePaperclip:
    """Minimal Paperclip API double: records requests, replays one response."""

    def __init__(self) -> None:
        self._status = 200
        self._body: Any = []
        self._raw_body: bytes | None = None
        self.requests: list[dict[str, Any]] = []

        fake = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def _handle(self) -> None:
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length) if length else b""
                fake.requests.append(
                    {
                        "method": self.command,
                        "path": self.path,
                        "headers": {k: v for k, v in self.headers.items()},
                        "body": raw.decode("utf-8") if raw else "",
                    }
                )
                body = fake._raw_body if fake._raw_body is not None else json.dumps(fake._body).encode()
                self.send_response(fake._status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            do_GET = _handle
            do_POST = _handle
            do_PATCH = _handle
            do_PUT = _handle
            do_DELETE = _handle

            def log_message(self, *args: Any) -> None:  # keep test output clean
                return

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    # ── control ──────────────────────────────────────────────────────────
    @property
    def base_url(self) -> str:
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}"

    def respond_with(self, payload: Any, status: int = 200) -> None:
        self._status = status
        self._body = payload
        self._raw_body = None

    def respond_status(self, status: int, text: str = "") -> None:
        self._status = status
        self._raw_body = text.encode()

    @property
    def last_headers(self) -> dict[str, str]:
        return self.requests[-1]["headers"] if self.requests else {}

    @property
    def last_request(self) -> dict[str, Any]:
        return self.requests[-1] if self.requests else {}

    def paths(self) -> list[str]:
        return [r["path"] for r in self.requests]

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()
