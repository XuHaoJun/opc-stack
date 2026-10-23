"""Dashboard native session management over the shared home's private transport.

Run as the dashboard runtime UID, with the default and expert homes mounted.
Creates only synthetic upgrade-smoke sessions and ends them; no operator history
is modified. Exercises real private ticket minting, WebSocket redemption, and
canonical mutations instead of directly dispatching an authority connection.
"""
import asyncio
from dataclasses import replace
from pathlib import Path
import uuid

from hermes_cli.gateway_client import connect_gateway
from hermes_cli.gateway_runtime import discover_gateway_endpoint
from hermes_constants import set_hermes_home_override, reset_hermes_home_override


async def verify(home):
    # Dashboard owner-forwarded requests keep the process's default home even
    # when their explicit endpoint belongs to an expert.
    token = set_hermes_home_override(Path('/opt/data'))
    try:
        found = discover_gateway_endpoint(home)
        assert found.state == 'ready' and found.endpoint is not None, (str(home), found)
        endpoint = replace(found.endpoint, control_home=found.endpoint.control_home or str(home))
        label = 'OPC native upgrade smoke ' + uuid.uuid4().hex
        async with connect_gateway(endpoint=endpoint) as client:
            created = await client.rpc('session.create', request_id=uuid.uuid4().hex,
                                       source='acp', cwd='/tmp', toolsets=[])
            sid = created['session_id']
            subscription = created['subscription_id']
            try:
                renamed = await client.rpc('session.mutate', session_id=sid,
                                           request_id=uuid.uuid4().hex,
                                           expected_revision=created['revision'],
                                           operation='rename', payload={'title': label})
                snapshot = await client.rpc('session.resume', session_id=sid)
                subscription = snapshot['subscription_id']
                assert renamed['title'] == label and snapshot['info']['title'] == label, (renamed, snapshot)
                assert snapshot['session_id'] == sid
            finally:
                await client.rpc('session.detach', session_id=sid, subscription_id=subscription,
                                 end_reason='upgrade_smoke')
        # The same Unix transport is not authorization: native tickets remain required.
        from websockets.asyncio.client import unix_connect
        from websockets.exceptions import InvalidStatus, ConnectionClosed
        url = endpoint.api_origin.replace('http:', 'ws:').replace('https:', 'wss:') + '/api/ws'
        try:
            async with unix_connect(endpoint.api_socket, uri=url, proxy=None) as unauthenticated:
                await unauthenticated.recv()
        except (InvalidStatus, ConnectionClosed):
            pass
        else:
            raise AssertionError('private transport bypassed native ticket authentication')
        print('PASS dashboard native rename and ticket gate: ' + str(home))
    finally:
        reset_hermes_home_override(token)


async def main():
    await verify(Path('/opt/data'))
    await verify(Path('/opt/data/profiles/agt-scientist'))


asyncio.run(main())
