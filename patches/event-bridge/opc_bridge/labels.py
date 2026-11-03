"""Track / style labels.

Track is a Paperclip label, not a field of ours: it must be filterable, visible
on the board, and readable without parsing prose. The description markers
(`Lane:`, `Track:`, `Style:`) are written for humans and are only an input to
label reconciliation — the resolver never parses ticket text.

Resolution rules (spec §11):
  * explicit `Track:`/`Style:` marker wins;
  * otherwise derived from the lane line (engineering → core/blueprint,
    prototype|research → lab/exploration);
  * both track labels, or a lane/track mismatch after reassignment, resolve to
    `unknown` — never "the first one". An unenforceable ticket must be visible.
"""

from __future__ import annotations

import re
from typing import Any, Iterable, Mapping

TRACK_LABELS = {"core": "track:core", "lab": "track:lab"}
STYLE_LABELS = {"blueprint": "style:blueprint", "exploration": "style:exploration"}
LABEL_COLORS = {
    "track:core": "#2563eb",
    "track:lab": "#7c3aed",
    "style:blueprint": "#0f766e",
    "style:exploration": "#b45309",
}

ALL_LABELS = list(TRACK_LABELS.values()) + list(STYLE_LABELS.values())

_MARKER = re.compile(r"^\s*(Lane|Track|Style)\s*:\s*([A-Za-z_-]+)\s*$", re.MULTILINE)

_DEFAULT_STYLE = {"core": "blueprint", "lab": "exploration"}


def parse_markers(text: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for key, value in _MARKER.findall(text or ""):
        found[key.lower()] = value.lower()
    return found


def labels_for_markers(markers: Mapping[str, str]) -> set[str]:
    lane = markers.get("lane", "")
    track = markers.get("track")
    if track not in TRACK_LABELS:
        track = "core" if lane == "engineering" else "lab" if lane in ("prototype", "research") else None
    style = markers.get("style")
    if style not in STYLE_LABELS:
        style = _DEFAULT_STYLE.get(track or "")
    labels: set[str] = set()
    if track:
        labels.add(TRACK_LABELS[track])
    if style:
        labels.add(STYLE_LABELS[style])
    return labels


def track_of(label_names: Iterable[str], agent: Mapping[str, Any] | None = None) -> str:
    labels = set(label_names)
    both = TRACK_LABELS["core"] in labels and TRACK_LABELS["lab"] in labels
    if both:
        return "unknown"
    if TRACK_LABELS["core"] in labels:
        return "core"
    if TRACK_LABELS["lab"] in labels:
        return "lab"
    return _track_from_agent(agent)


def _track_from_agent(agent: Mapping[str, Any] | None) -> str:
    if not agent:
        return "unknown"
    role = str(agent.get("role") or "")
    name = str(agent.get("name") or "")
    if role == "engineer":
        return "core"
    if name in ("Prototyper", "Scientist"):
        return "lab"
    return "unknown"


def ensure_labels(client) -> dict[str, str]:
    """Create the four labels if absent; return name → id."""
    existing = {str(row.get("name")): str(row.get("id")) for row in client.labels()}
    result: dict[str, str] = {}
    for name in ALL_LABELS:
        if name in existing:
            result[name] = existing[name]
            continue
        created = client.create_label(name, LABEL_COLORS[name])
        if created.get("id"):
            result[name] = str(created["id"])
    return result
