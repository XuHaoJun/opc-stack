"""Thin Paperclip REST client.

One request helper, one error type. Everything the bridge needs from the work
plane is a read of state plus the handful of control calls (agent pause, run
cancel, issue label/status). No caching of work state here — Paperclip is the
authority, and a stale cache would be a second one.

`PaperclipError` deliberately carries only the status and the response body.
The bearer token is never interpolated into a message, so a logged failure
cannot leak the board key.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Iterable, Mapping

DEFAULT_TIMEOUT = 15.0


class PaperclipError(Exception):
    def __init__(self, status: int, body: str) -> None:
        self.status = status
        self.body = body
        super().__init__(f"paperclip error {status}: {body[:300]}")


def _as_list(payload: Any, *envelopes: str) -> list[dict]:
    if isinstance(payload, list):
        return payload
    if isinstance(payload, Mapping):
        for key in envelopes:
            value = payload.get(key)
            if isinstance(value, list):
                return value
        for value in payload.values():
            if isinstance(value, list):
                return value
    return []


class Paperclip:
    def __init__(
        self,
        base_url: str,
        api_key: str,
        opener: Callable[..., Any] = urllib.request.urlopen,
        timeout: float = DEFAULT_TIMEOUT,
        company_id: str | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self._opener = opener
        self._timeout = timeout
        self._company_id = company_id

    # ── transport ────────────────────────────────────────────────────────
    def _request(self, method: str, path: str, body: Any | None = None) -> Any:
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(self.base_url + path, data=data, method=method)
        request.add_header("Authorization", f"Bearer {self.api_key}")
        request.add_header("Accept", "application/json")
        if data is not None:
            request.add_header("Content-Type", "application/json")

        try:
            with self._opener(request, timeout=self._timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            exc.close()
            raise PaperclipError(exc.code, detail) from None
        except urllib.error.URLError as exc:
            raise PaperclipError(0, f"unreachable: {exc.reason}") from None

        if not raw:
            return {}
        try:
            return json.loads(raw)
        except ValueError:
            raise PaperclipError(0, "non-JSON response") from None

    # ── company ──────────────────────────────────────────────────────────
    def company(self) -> str:
        if self._company_id is None:
            rows = _as_list(self._request("GET", "/api/companies"), "companies")
            if not rows or not rows[0].get("id"):
                raise PaperclipError(0, "no company visible to this key")
            self._company_id = str(rows[0]["id"])
        return self._company_id

    # ── issues ───────────────────────────────────────────────────────────
    def issues_updated_since(
        self, iso: str, limit: int = 100, offset: int = 0
    ) -> list[dict]:
        query = urllib.parse.urlencode(
            {
                "updatedSince": iso,
                "limit": limit,
                "offset": offset,
                "sortField": "updated",
                "sortDir": "asc",
            }
        )
        payload = self._request("GET", f"/api/companies/{self.company()}/issues?{query}")
        return _as_list(payload, "issues")

    def issue(self, issue_id: str) -> dict:
        return self._request("GET", f"/api/issues/{issue_id}")

    def issues_with_status(self, status: str, limit: int = 100) -> list[dict]:
        query = urllib.parse.urlencode({"status": status, "limit": limit})
        payload = self._request("GET", f"/api/companies/{self.company()}/issues?{query}")
        return _as_list(payload, "issues")

    def comments(self, issue_id: str, limit: int = 500) -> list[dict]:
        payload = self._request(
            "GET", f"/api/issues/{issue_id}/comments?{urllib.parse.urlencode({'limit': limit})}"
        )
        return _as_list(payload, "comments")

    def patch_issue(self, issue_id: str, body: Mapping[str, Any]) -> dict:
        return self._request("PATCH", f"/api/issues/{issue_id}", dict(body))

    # ── agents ───────────────────────────────────────────────────────────
    def agents(self) -> list[dict]:
        payload = self._request("GET", f"/api/companies/{self.company()}/agents")
        return _as_list(payload, "agents")

    def agent(self, agent_id: str) -> dict:
        return self._request("GET", f"/api/agents/{agent_id}")

    def patch_agent(self, agent_id: str, body: Mapping[str, Any]) -> dict:
        return self._request("PATCH", f"/api/agents/{agent_id}", dict(body))

    # ── runs ─────────────────────────────────────────────────────────────
    def run(self, run_id: str) -> dict:
        return self._request("GET", f"/api/heartbeat-runs/{run_id}")

    def runs_for_issue(self, issue_id: str) -> list[dict]:
        payload = self._request("GET", f"/api/issues/{issue_id}/runs")
        return _as_list(payload, "runs")

    def live_runs(self) -> list[dict]:
        payload = self._request("GET", f"/api/companies/{self.company()}/live-runs")
        return _as_list(payload, "runs")

    def heartbeat_runs(self, limit: int = 200) -> list[dict]:
        query = urllib.parse.urlencode({"limit": limit})
        payload = self._request("GET", f"/api/companies/{self.company()}/heartbeat-runs?{query}")
        return _as_list(payload, "runs")

    def cancel_run(self, run_id: str) -> dict:
        return self._request("POST", f"/api/heartbeat-runs/{run_id}/cancel", {})

    # ── labels ───────────────────────────────────────────────────────────
    def labels(self) -> list[dict]:
        payload = self._request("GET", f"/api/companies/{self.company()}/labels")
        return _as_list(payload, "labels")

    def create_label(self, name: str, color: str) -> dict:
        return self._request(
            "POST", f"/api/companies/{self.company()}/labels", {"name": name, "color": color}
        )
