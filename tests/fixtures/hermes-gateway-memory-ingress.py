"""Native ACP admission regression; executable without pytest or a running daemon.

Run with the target Hermes interpreter and source on PYTHONPATH. The authority,
SQLite admissions, ACP retry/event pump, turn invocation and ingress projector are
real. Only conversation execution (the LLM boundary) is replaced by a projector
consumer, so assertions concern eligible capture, not echoed keyword arguments.
"""
import asyncio
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

import acp
from acp.schema import TextContentBlock
from acp_adapter.gateway_server import GatewayACPAgent
from gateway.config import GatewayConfig
from gateway.session import SessionStore
from gateway.session_authority import initialize_session_authority
from gateway.session_cli_turn import cli_turn, cli_turn_scope
from gateway.session_controls import AuthorityConnection
from gateway.run_turn_runner import TurnRunner
from hermes_cli.gateway_client import GatewayClientError, GatewayRPCError
from hermes_state_runtime import list_session_admissions

# Host checkout and deployed frontdoor both expose the same plugin package.
for candidate in (Path.cwd() / 'patches/hermes',
                  Path('/opt/data/plugins')):
    if candidate.is_dir():
        sys.path.insert(0, str(candidate))
from memory_tencentdb.ingress import project

OWNER = 'a' * 64
META = {'buzz': {'memoryEvents': [{
    'eventId': 'evt-native-ingress', 'authorPubkey': OWNER,
    'channelId': 'channel-native-ingress', 'threadId': None,
    'role': 'trigger', 'content': 'native capture one',
}]}}


class Wire:
    """Same real-authority transport as upstream test_gateway_submit_retry.py."""
    def __init__(self):
        self.loop = asyncio.get_running_loop()
        self.events = asyncio.Queue()
        self.serial = 0
        self.lose_ack = False

    def write(self, frame):
        self.loop.call_soon_threadsafe(self.events.put_nowait, frame)
        return True

    async def rpc(self, method, **params):
        self.serial += 1
        reply = await self.viewer.dispatch({'id': self.serial, 'method': method, 'params': params})
        if 'error' in reply:
            raise GatewayRPCError(reply['error'].get('data', {}).get('reason', 'request_failed'))
        if method == 'prompt.submit' and self.lose_ack:
            self.lose_ack = False
            raise GatewayClientError('Gateway disconnected; turn outcome is unknown.')
        return reply['result']


def blocks(meta=META):
    result = [acp.text_block('plain unannotated block')]
    result.append(TextContentBlock(type='text', text='same words', field_meta=copy.deepcopy(meta))
                  if meta is not None else acp.text_block('same words'))
    return result


async def regression(home):
    os.environ['HERMES_HOME'] = str(home)
    # Real profile input rather than monkeypatching config/policy resolution.
    (home / 'config.yaml').write_text(
        json.dumps({'platform_toolsets': {'acp': []}}), encoding='utf-8')
    store = SessionStore(home / 'sessions', GatewayConfig())
    captures, messages, scopes = [], [], []

    # This is the only execution double: replace the model call with the actual
    # downstream eligibility policy. TurnRunner must supply admission-local data.
    class ConversationBoundary:
        def run_conversation(self, user_message, *, memory_ingress=None, **kwargs):
            messages.append(user_message)
            captures.append(project(memory_ingress or [], {OWNER}).capture)
            return {'final_response': 'ACK', 'completed': True, 'messages': []}

    conversation = ConversationBoundary()
    runner = SimpleNamespace(_session_db=store._db, session_store=store, _draining=False,
                             adapters={}, _adapter_for_source=lambda source: None,
                             _cached_agent_for=lambda route: None,
                             _evict_cached_agent=lambda route: None,
                             _resolve_session_agent_runtime=lambda **kwargs: ('frozen', {}),
                             _consume_pending_native_image_paths=lambda key: [])

    async def answer(event):
        from gateway.session_results import execution_result
        scopes.append((str(event.message_id), cli_turn(event.message_id)))
        ctx = SimpleNamespace(session_key=authority.sessions[sid].route, session_id=sid, message=event.text,
                              inbound_message_id=event.message_id, source=event.source,
                              title_user_message=None, persist_user_display_kind=None,
                              persist_user_display_metadata=None, moa_config=None,
                              mute_notification_reply=False)
        # Bypass unrelated route/model construction, not the production invocation.
        turn = object.__new__(TurnRunner)
        turn._runner, turn._ctx, turn._approval_owner = runner, ctx, None
        result = turn._run_conversation_with_approval(conversation, [], None, None, None)
        execution_result.get()['result'] = result
        return result['final_response']

    runner._handle_message = answer
    authority = await initialize_session_authority(runner, profile_id='p', instance_id='owner')
    wire = Wire()
    wire.viewer = AuthorityConnection(authority, wire, {'user_id': 'editor', 'native_bootstrap': True})
    created = await wire.rpc('session.create', request_id='native-ingress', source='acp',
                             cwd=str(home), model='frozen', toolsets=[])
    sid = created['session_id']
    agent = GatewayACPAgent()
    agent._gateway = wire
    agent._conn = SimpleNamespace(session_update=lambda **kwargs: asyncio.sleep(0))
    agent._snapshots[sid] = await wire.rpc('session.resume', session_id=sid)
    agent._event_task = asyncio.create_task(agent._events())
    schedule = authority._schedule

    def rows():
        return list_session_admissions(authority.db, session_id=sid, pending_only=False)

    async def prompt(meta=META):
        response = await asyncio.wait_for(agent.prompt(blocks(meta), sid), 10)
        assert response.stop_reason == 'end_turn'

    try:
        # Admission survives a lost acknowledgement and retains per-block metadata.
        authority._schedule = lambda ref: None
        wire.lose_ack = True
        try:
            await agent.prompt(blocks(), sid)
            raise AssertionError('lost submit acknowledgement was not surfaced')
        except GatewayClientError as exc:
            assert 'outcome is unknown' in str(exc)
        first = rows()
        assert len(first) == 1
        assert first[0]['payload']['cli_turn_v1']['memory_ingress'] == [META]
        authority._schedule = schedule
        await prompt()
        assert len(rows()) == 1 and captures == ['native capture one'], (rows(), captures)
        assert 'plain unannotated block' in messages[0] and 'same words' in messages[0]

        # Same text but changed metadata is NOT the retained lost-ack retry.
        authority._schedule = lambda ref: None
        wire.lose_ack = True
        try:
            await agent.prompt(blocks(), sid)
            raise AssertionError('lost submit acknowledgement was not surfaced')
        except GatewayClientError:
            pass
        changed = copy.deepcopy(META)
        changed['buzz']['memoryEvents'][0]['content'] = 'native capture two'
        authority._schedule = schedule
        await prompt(changed)
        assert len(rows()) == 3, 'metadata-sensitive retry must admit changed metadata independently'
        assert captures == ['native capture one', 'native capture one', 'native capture two'], captures
        await prompt(None)
        assert captures[-1] is None, 'unannotated turn inherited prior metadata'
        assert 'memory_ingress' not in scopes[-1][1]

        # Public authenticated viewers cannot forge the trusted native field.
        public = Wire()
        public.viewer = AuthorityConnection(authority, public, {'user_id': 'editor'})
        try:
            await public.rpc('session.resume', session_id=sid)
            try:
                await public.rpc('prompt.submit', session_id=sid, input_id='public', text='same words', memory_ingress=[META])
                raise AssertionError('public viewer accepted native ingress')
            except GatewayRPCError as exc:
                assert 'permission_denied' in str(exc), str(exc)
        finally:
            await public.viewer.close()

        before = len(rows())
        for index, malformed in enumerate(('not-a-list', {}, [None], ['not-a-dict'])):
            try:
                await wire.rpc('prompt.submit', session_id=sid, input_id='malformed-' + str(index),
                               text='same words', memory_ingress=malformed)
                raise AssertionError('malformed metadata admitted: ' + repr(malformed))
            except GatewayRPCError as exc:
                assert 'invalid_params' in str(exc), str(exc)
        assert len(rows()) == before, 'malformed input committed an admission'

        # Whole-turn metadata cannot be transferred by the text-only edit/steer
        # protocol. Refusal leaves the original eligible admission untouched.
        authority._schedule = lambda ref: None
        old = await wire.rpc('prompt.submit', session_id=sid, input_id='queued-old',
                             text='queued old', memory_ingress=[META])
        before = len(rows())
        from gateway.session_queued_controls import queued_controls
        queued_row = next(row for row in rows() if row['admission_id'] == old['admission_id'])
        # A plain version on this same interactive session IS editable, proving
        # refusal below is due to the metadata envelope, not session provenance.
        plain_row = {**queued_row, 'payload': {'text': 'plain queued text'}}
        assert queued_controls(authority, plain_row) == ['steer', 'replace']
        assert queued_controls(authority, queued_row) == []
        for method in ('prompt.replace_queued', 'prompt.steer_queued'):
            try:
                edit = {'submission_id': 'queued-edit', 'text': 'queued replacement'} \
                    if method == 'prompt.replace_queued' else {}
                await wire.rpc(method, session_id=sid, admission_id=old['admission_id'], **edit)
                raise AssertionError('text-only queued control accepted metadata-bearing turn')
            except GatewayRPCError as exc:
                assert 'unsupported_control' in str(exc), str(exc)
        assert len(rows()) == before
        old_row = next(row for row in rows() if row['admission_id'] == old['admission_id'])
        assert old_row['payload']['cli_turn_v1']['memory_ingress'] == [META]
        await wire.rpc('prompt.cancel', session_id=sid, admission_id=old['admission_id'])
        authority._schedule = schedule
        await prompt(None)
        assert captures[-1] is None, 'turn after refused replacement inherited old eligibility'

        # Exception unwinding must clear the context and admission-id guard.
        try:
            with cli_turn_scope('exception', {'memory_ingress': [META]}):
                assert project(cli_turn('exception')['memory_ingress'], {OWNER}).capture == 'native capture one'
                assert project(cli_turn('other').get('memory_ingress', []), {OWNER}).capture is None
                raise RuntimeError('synthetic execution failure')
        except RuntimeError:
            pass
        assert project(cli_turn('exception').get('memory_ingress', []), {OWNER}).capture is None
        return {'E2E_INGRESS_N': 1, 'E2E_META_OK': 1, 'E2E_USER_OK': 1}
    finally:
        authority._schedule = schedule
        agent._event_task.cancel()
        try:
            await agent._event_task
        except asyncio.CancelledError:
            pass
        await wire.viewer.close()
        store.close_all_db_handles()


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='opc-native-ingress-') as directory:
        result = asyncio.run(regression(Path(directory)))
    for key, value in result.items():
        print(f'{key}={value}')
