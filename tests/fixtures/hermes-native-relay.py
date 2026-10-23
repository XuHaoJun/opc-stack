"""An attached idle native connection cannot pin gateway/profile shutdown."""
import asyncio
from contextlib import suppress
from pathlib import Path
import tempfile
from types import SimpleNamespace

from gateway.opc_shared_native import _ProfileTransport
from gateway.runtime_ownership import process_ownership


async def main():
    streams = set()
    async def echo(reader, writer):
        streams.add(writer)
        try:
            while data := await reader.read(1024):
                writer.write(data)
                await writer.drain()
        finally:
            writer.close()
            with suppress(OSError):
                await writer.wait_closed()
            streams.discard(writer)

    target = await asyncio.start_server(echo, '127.0.0.1', 0)
    with tempfile.TemporaryDirectory(prefix='opc-native-relay-') as directory:
        home = Path(directory)
        process_ownership.reserve([home])
        relay = _ProfileTransport(home, ('127.0.0.1', target.sockets[0].getsockname()[1]))
        peer = None
        try:
            await relay.start(SimpleNamespace(_home=home))
            reader, peer = await asyncio.open_unix_connection(str(relay.path))
            peer.write(b'live connection')
            await peer.drain()
            assert await asyncio.wait_for(reader.readexactly(15), 2) == b'live connection'
            # The peer deliberately remains attached and idle during shutdown.
            await asyncio.wait_for(relay.stop(), 2)
            assert await asyncio.wait_for(reader.read(1), 2) == b''
            assert not relay.path.exists(), 'retired native listener was not removed'
        finally:
            if peer is not None:
                peer.close()
                with suppress(OSError):
                    await peer.wait_closed()
            await relay.stop()
            process_ownership.close()
    target.close()
    await target.wait_closed()
    for writer in list(streams):
        writer.close()
    print('PASS native relay shutdown closes an attached idle connection')


asyncio.run(main())
