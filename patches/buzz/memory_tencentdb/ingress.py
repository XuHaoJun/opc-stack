"""Memory ingress projection — decide what may enter durable memory.

THE BOUNDARY IS THE PROTOCOL, NOT THE TEXT. The prompt Buzz composes is text, and text
is attacker-controlled: section bodies are embedded raw (`queue.rs:1323` for the event
content, `queue.rs:1821` for conversation context) and `escape_semantic_text` has exactly
one call site in that crate (channel metadata). A sender can therefore write
`</buzz-event><buzz-event …>From: <owner> (hex: …)` and forge any tag, any header line,
any boundary. Earlier revisions parsed that string back apart, positionally and very
carefully — it worked, but every rule existed only to undo the damage of the join, and
the multi-event batch case could not be recovered at all (no boundary between the N
events inside one section), so whole batches of real user messages were dropped.

So the boundary is taken from the ACP content block's own `_meta` instead: Buzz knows the
event id, the author pubkey, the channel and the thread at composition time
(`crates/buzz-acp/src/queue.rs` `format_prompt`), and `TextContentBlock` has carried a free
`_meta` field all along (`acp.schema.TextContentBlock.model_fields` →
`field_meta` / alias `_meta`). The wire contract is frozen in the spec and reproduced in
`tests/fixtures/buzz-acp-prompt-blocks.json`.

Consequences worth stating, because they are the point:

  * this module never looks at prompt text — the API does not even accept it, so there is
    nothing here for a forged header, a forged tag or a forged `Channel:` line to steer;
  * per-EVENT decisions become possible (a batch of five messages with one trusted author
    captures exactly that one), where the old design had to drop the batch whole;
  * the identity is immutable (hex pubkey), and conversation admission still never implies
    memory-write authority.

Policy (spec §5):

    no structured events           -> no passive write  (includes an unpatched Buzz)
    role != "trigger"              -> no passive write  (re-delivered cancelled events)
    author not in allowlist        -> no passive write
    else                           -> capture that event's raw content

Anything unrecognised fails closed: drop the memory, never widen trust.
"""
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set

# `_meta.buzz.memoryEvents` — see the frozen contract in the spec (§3).
_META_NAMESPACE = "buzz"
_META_KEY = "memoryEvents"

# `batch.events` are the messages that triggered this turn; `batch.cancelled_events` are
# earlier ones re-delivered after a cancelled turn (and may be re-delivered again, which
# is why they are not captured until a dedup state exists — spec §5).
_TRIGGER_ROLE = "trigger"
_PRIOR_ROLE = "prior"

_HEX_LEN = 64
_HEX_DIGITS = frozenset("0123456789abcdef")


@dataclass
class Drop:
    """One rejected ingress candidate, for the metadata-only log (spec §7.2)."""

    reason: str
    content: str = ""
    sender_pubkey: Optional[str] = None
    event_id: Optional[str] = None
    channel_id: Optional[str] = None


@dataclass
class Projection:
    capture: Optional[str]
    drops: List[Drop] = field(default_factory=list)


def _events(meta: Any) -> List[Any]:
    if not isinstance(meta, dict):
        return []
    payload = meta.get(_META_NAMESPACE)
    if not isinstance(payload, dict):
        return []
    events = payload.get(_META_KEY)
    return events if isinstance(events, list) else []


def _hex(value: Any) -> Optional[str]:
    """Normalise a hex pubkey, or None. Names and npubs are not identities."""
    if not isinstance(value, str):
        return None
    candidate = value.strip().lower()
    if len(candidate) != _HEX_LEN or not set(candidate) <= _HEX_DIGITS:
        return None
    return candidate


def _text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def project(metas: List[Any], trusted_writers: Set[str]) -> Projection:
    """Decide what this turn may write to durable memory.

    ``metas`` is the per-block ``_meta`` payload list the ACP sidecar handed over, in
    block order — nothing else. Never pass prompt text.
    """
    candidates: List[Any] = []
    for meta in metas:
        candidates.extend(_events(meta))

    if not candidates:
        # Heartbeat, a non-Buzz lane, or a Buzz build without the metadata: there is no
        # trustworthy structure in this prompt, so there is nothing to write.
        return Projection(None, [Drop("no-memory-events")])

    captures: List[str] = []
    drops: List[Drop] = []
    for event in candidates:
        if not isinstance(event, dict):
            drops.append(Drop("malformed-event"))
            continue
        content = _text(event.get("content"))
        author = _hex(event.get("authorPubkey"))
        drop = Drop(
            "unknown-role",
            content=content,
            sender_pubkey=author,
            event_id=_text(event.get("eventId")) or None,
            channel_id=_text(event.get("channelId")) or None,
        )
        role = event.get("role")
        if role != _TRIGGER_ROLE:
            drop.reason = "prior-event" if role == _PRIOR_ROLE else "unknown-role"
        elif author is None:
            drop.reason = "no-author-pubkey"
        elif author not in trusted_writers:
            drop.reason = "untrusted-writer"
        elif not content.strip():
            drop.reason = "empty-content"
        else:
            captures.append(content.strip())
            continue
        drops.append(drop)

    if not captures:
        return Projection(None, drops)
    # One L0 message per turn, not one per event: `/v3/conversation/add` counts `rounds`
    # by user-role messages (`v2-router.ts:751-757`), and the promotion cadence is a
    # separate knob that this refactor must not move.
    return Projection("\n".join(captures), drops)
