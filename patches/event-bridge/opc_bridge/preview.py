"""Stop ticket previews when their ticket is over.

A code ticket's preview is a Paperclip runtime service named exactly
`preview` on the ticket's execution workspace (started by the front door with
`opc-paperclip preview up`). This module is the other half of that lifecycle
and mirrors `opc-paperclip preview down`:

  1. POST .../runtime-services/stop with a selector for the preview service
     ONLY (`{runtimeServiceId}`, falling back to `{serviceIndex}`). An empty
     body means "every service" upstream, so it is never sent.
  2. PATCH the workspace's `config.serviceStates[<index>] = "stopped"`, keyed
     by the service's index in `config.workspaceRuntime.services[]`, or
     Paperclip's startup recovery revives it.

Two triggers: `sweep` is level-triggered (source issue done/cancelled, so a
bridge outage is caught on the next loop); `stop_for_rework` is the edge for
in_review -> todo/in_progress, which the level sweep cannot see. Every failure
is logged and swallowed: stopping a preview must never block event delivery.
"""

from __future__ import annotations

from typing import Any, Callable, Mapping

PREVIEW_SERVICE = "preview"
_OVER = {"done", "cancelled"}


def _preview_service(workspace: Mapping[str, Any]) -> Mapping[str, Any] | None:
    for service in workspace.get("runtimeServices") or []:
        if service.get("serviceName") == PREVIEW_SERVICE:
            return service
    return None


def _preview_index(workspace: Mapping[str, Any]) -> int | None:
    services = ((workspace.get("config") or {}).get("workspaceRuntime") or {}).get("services") or []
    for index, entry in enumerate(services):
        if entry.get("name") == PREVIEW_SERVICE:
            return index
    return None


_STOPPABLE = {"running", "starting", "provisioning"}


def _running_service(workspace: Mapping[str, Any]) -> bool:
    # Only a preview this workspace declares itself: a shared workspace can list
    # the project workspace's services, which are not ours to stop.
    if _preview_index(workspace) is None:
        return False
    service = _preview_service(workspace)
    return service is not None and service.get("status") in _STOPPABLE


def _state_stale(workspace: Mapping[str, Any]) -> bool:
    """Service is down but serviceStates still says running (a PATCH that failed
    after a successful stop) — startup recovery would bring it back."""
    if _preview_service(workspace) is None:
        return False
    index = _preview_index(workspace)
    if index is None:
        return False
    states = (workspace.get("config") or {}).get("serviceStates") or {}
    return index is not None and states.get(str(index)) == "running"


def live_previews(workspaces: list[dict]) -> list[tuple[str, str]]:
    return [
        (str(w["id"]), str(w.get("sourceIssueId") or ""))
        for w in workspaces
        if _running_service(w)
    ]


def _stop_preview(pc, workspace: Mapping[str, Any]) -> None:
    index = _preview_index(workspace)
    service = _preview_service(workspace)
    if service is not None and service.get("status") in _STOPPABLE:
        if service.get("id"):
            selector: dict[str, Any] = {"runtimeServiceId": service["id"]}
        elif index is not None:
            selector = {"serviceIndex": index}
        else:
            raise ValueError("no way to select the preview service")
        pc.stop_runtime_service(workspace["id"], selector)
    if index is not None:
        states = dict((workspace.get("config") or {}).get("serviceStates") or {})
        states[str(index)] = "stopped"
        pc.patch_execution_workspace(workspace["id"], {"config": {"serviceStates": states}})


def _stop_matching(pc, workspaces, wanted: Callable[[Mapping[str, Any]], bool], log) -> list[str]:
    stopped: list[str] = []
    for workspace in workspaces:
        if not (_running_service(workspace) or _state_stale(workspace)):
            continue
        if not wanted(workspace):
            continue
        try:
            _stop_preview(pc, workspace)
        except Exception as exc:
            log(f"[preview] stop failed for workspace {workspace.get('id')}: {exc}")
            continue
        stopped.append(str(workspace["id"]))
        log(f"[preview] stopped preview on workspace {workspace.get('id')}")
    return stopped


def sweep(pc, issue_status: Callable[[str], str], log: Callable[[str], Any] = print) -> list[str]:
    try:
        workspaces = pc.execution_workspaces()
    except Exception as exc:
        log(f"[preview] cannot list execution workspaces: {exc}")
        return []

    cache: dict[str, str | None] = {}

    def over(workspace: Mapping[str, Any]) -> bool:
        issue_id = str(workspace.get("sourceIssueId") or "")
        if not issue_id:
            return False
        if issue_id not in cache:
            try:
                cache[issue_id] = issue_status(issue_id)
            except Exception as exc:
                log(f"[preview] cannot read status of {issue_id}: {exc}")
                cache[issue_id] = None
        return cache[issue_id] in _OVER

    return _stop_matching(pc, workspaces, over, log)


def sweep_issues(pc, log: Callable[[str], Any] = print) -> list[str]:
    """`sweep` with the status read from Paperclip."""
    return sweep(pc, lambda issue_id: str(pc.issue(issue_id).get("status") or ""), log=log)


def stop_for_rework(pc, issue_id: str, log: Callable[[str], Any] = print) -> list[str]:
    try:
        workspaces = pc.execution_workspaces(issue_id)
    except Exception as exc:
        log(f"[preview] cannot list execution workspaces for {issue_id}: {exc}")
        return []
    return _stop_matching(
        pc, workspaces, lambda w: str(w.get("sourceIssueId") or "") == issue_id, log
    )
