"""OPC ACP metadata is provider egress, without rewriting event provenance."""
import copy

from agent.memory_manager import MemoryManager
from agent.memory_provider import MemoryProvider


class Recorder(MemoryProvider):
    @property
    def name(self):
        return "opc-ingress-recorder"

    def initialize(self, session_id="", **kwargs):
        pass

    def is_available(self):
        return True

    def system_prompt_block(self):
        return ""

    def get_tool_schemas(self):
        return []

    def sync_turn(self, user_content, assistant_content, *, memory_ingress=None, **kwargs):
        self.seen = (user_content, assistant_content, memory_ingress)


def test_ingress_redaction_shares_learned_secrets_but_preserves_provenance(monkeypatch):
    monkeypatch.setattr("agent.redact._REDACT_ENABLED", False)
    key = "AQ.Ab8RN6Jx2kq9Zs0VwT4yLm3PbQe7HcUfGdA1nX5oIr"
    event = {"eventId": "a" * 64, "authorPubkey": "b" * 64,
             "channelId": "c" * 64, "threadId": "d" * 64,
             "role": "trigger", "content": f"Remember {key}"}
    ingress = [{"buzz": {"memoryEvents": [event]}}]
    original = copy.deepcopy(ingress)
    provider = Recorder()
    manager = MemoryManager()
    manager.add_provider(provider)
    manager.sync_all("read config", f"Your key is {key}",
                     messages=[{"role": "tool", "content": f'{{"api_key": "{key}"}}'}],
                     memory_ingress=ingress)
    manager.flush_pending(timeout=5.0)
    assert key not in repr(provider.seen)
    redacted = provider.seen[2][0]["buzz"]["memoryEvents"][0]
    assert {k: v for k, v in redacted.items() if k != "content"} == {
        k: v for k, v in event.items() if k != "content"}
    assert redacted["content"].startswith("Remember ")
    assert ingress == original


if __name__ == "__main__":
    from contextlib import ExitStack
    from types import SimpleNamespace
    from unittest.mock import patch

    with ExitStack() as stack:
        monkeypatch = SimpleNamespace(
            setattr=lambda target, value: stack.enter_context(patch(target, value)))
        test_ingress_redaction_shares_learned_secrets_but_preserves_provenance(monkeypatch)
    print("PASS metadata redaction preserves provenance and caller data")
