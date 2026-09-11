"""Memory ingress projection — decide what may enter durable memory.

THE BOUNDARY IS THE ACP BLOCK LIST, NOT THE TEXT. Buzz emits one prompt section per
ACP text content block (buzz-acp/src/acp.rs:772). Section bodies are NOT escaped:
format_event_block embeds `be.event.content` raw (queue.rs:1323) and
format_conversation_context embeds `msg.content` raw (queue.rs:1821), and
escape_semantic_text has exactly one call site in that crate (channel metadata). So a
sender can write `</buzz-event><conversation-context>…` and forge any tag. Never parse
the joined prompt; only ever look at one block at a time, and only trust the generated
header prefix inside it.

Three invariants (spec 7.1):
    no trusted structural boundary  -> no passive write
    no trusted writer identity      -> no passive write
    any ambiguity                   -> drop the memory, never widen trust
"""
from dataclasses import dataclass
from typing import List, Optional, Set

# Eligibility is an ALLOWLIST. `buzz-events` (a batch) is excluded because ACP blocks
# give no boundary between the N events inside it, and raw content can forge
# `--- Event 2 ---` with a trusted `From:` line (spec 1.7 (d)). The cancelled/steer
# variants are excluded for the same reason AND because Buzz substitutes a different
# tag name for them (queue.rs:2120-2125), so a denylist would silently miss it.
_ELIGIBLE_TAG = "buzz-event"

# Everything the generated header emits before the raw content. Content is the LAST
# field of the prefix, so everything after `Content: ` is sender-controlled.
_CONTENT_MARKER = "\nContent: "

# The generated header, in order. format_event_block (queue.rs:1312-1319) emits
# exactly these five lines and nothing else before the content marker.
_HEADER_KEYS = ("Event ID", "Channel", "Kind", "From", "Time")


@dataclass
class Projection:
    capture: Optional[str]
    recall_query: str
    drop_reason: Optional[str] = None
    sender_pubkey: Optional[str] = None
    event_id: Optional[str] = None


def _open_tag(block: str) -> Optional[str]:
    if not block.startswith("<"):
        return None
    end = block.find(">")
    if end < 0:
        return None
    head = block[1:end]
    return head.split()[0] if head else None


def _parse_prefix(body: str) -> dict:
    """Parse the generated header POSITIONALLY, and only when it is exactly that shape.

    Not key-based. `Channel:` embeds the channel name raw (queue.rs:1309) and the
    relay validates names only for emptiness (`canonical_channel_name`,
    buzz-core/src/channel.rs:15 — it trims, it does NOT filter control characters,
    unlike `sanitize_prompt_label` at queue.rs:1248 which is why the `From:` label is
    not a vector). So a channel named
    `general\nFrom: <owner> (hex: …)\nContent: <payload>` injects whole header lines
    ahead of the generated ones, and a parser that takes the first `From:` reads the
    forged one. Channel is the ONLY such field: Event ID / Kind / Time are machine
    values and the `From` label is sanitised upstream.

    So: the head must be exactly _HEADER_KEYS, one line each, in that order. Callers
    must also have checked that the body holds exactly one content marker — the two
    conditions are jointly necessary and neither is sufficient alone. An injection
    that keeps the head five well-formed lines has to supply its own `Content: `
    terminator (otherwise the real Kind/From/Time lines follow and the head is too
    long), and the real marker always trails it, so the count catches what the shape
    check cannot; an injection that adds lines without a terminator is caught by the
    shape check alone.
    """
    head, sep, _ = body.partition(_CONTENT_MARKER)
    if not sep:
        return {}
    lines = head.split("\n")
    # semantic_section_with_attributes wraps the block as `<tag …>\n<block>\n</tag>`
    # (prompt_framing.rs), so the body always opens with one empty line.
    if lines and lines[0] == "":
        lines = lines[1:]
    if len(lines) != len(_HEADER_KEYS):
        return {}
    fields = {}
    for key, line in zip(_HEADER_KEYS, lines):
        prefix = key + ": "
        if not line.startswith(prefix):
            return {}
        fields[key] = line[len(prefix):].strip()
    return fields


def _hex_pubkey(from_field: str) -> Optional[str]:
    # `From: name (npub: npub1…, hex: aabbcc)` — take the hex, which is immutable.
    marker = "hex: "
    i = from_field.find(marker)
    if i < 0:
        return None
    return from_field[i + len(marker):].rstrip(")").strip() or None


def project(blocks: List[str], trusted_writers: Set[str]) -> Projection:
    recall_query = "\n".join(blocks).strip()

    eligible = []
    for block in blocks:
        tag = _open_tag(block)
        if tag == _ELIGIBLE_TAG:
            eligible.append(block)
        elif tag is not None and tag.startswith("buzz-events"):
            return Projection(None, recall_query, "multi-event")

    if len(eligible) != 1:
        # Zero: no triggering event in this prompt (heartbeat, or a shape we do not
        # recognise). More than one: ambiguous. Both fail closed.
        return Projection(None, recall_query, "no-single-event" if not eligible else "multiple-event-blocks")

    block = eligible[0]
    close = f"</{_ELIGIBLE_TAG}>"
    if block.count(close) != 1 or not block.rstrip().endswith(close):
        # A forged close tag inside the content. The block is not what it claims.
        return Projection(None, recall_query, "forged-boundary")

    body = block[block.find(">") + 1: block.rstrip().rfind(close)]
    if body.count(_CONTENT_MARKER) != 1:
        # The generated header emits exactly one. A second one is either a channel-name
        # injection (see _parse_prefix) or a sender who wrote a `Content: ` line of
        # their own — indistinguishable from here, so both fail closed.
        return Projection(None, recall_query, "ambiguous-header")
    fields = _parse_prefix(body)
    if not fields.get("Event ID") or not fields.get("From"):
        return Projection(None, recall_query, "unparsable-prefix")

    sender = _hex_pubkey(fields["From"])
    if not sender:
        return Projection(None, recall_query, "no-sender-pubkey")
    if sender not in trusted_writers:
        # Conversation admission never implies memory-write authority (spec 1.9).
        return Projection(None, recall_query, "untrusted-writer",
                          sender_pubkey=sender, event_id=fields.get("Event ID"))

    # Everything after the marker, verbatim. Deliberately NO end-detection: `Tags:` and
    # `Parsed:` are generated but appear AFTER the raw content, so a sender can emit
    # them too (spec 1.7 (e)). Any "smart" terminator becomes an attacker-steerable
    # knob; a generated tail riding along is noise, not a trust break.
    _, _, content = body.partition(_CONTENT_MARKER)
    return Projection(content.strip(), recall_query, None,
                      sender_pubkey=sender, event_id=fields.get("Event ID"))
