#!/usr/bin/env python3
"""Synthetic TCP echo target and adversarial proxy responses, bound only to loopback."""
import asyncio, ipaddress, json, sys
from pathlib import Path
output = Path(sys.argv[1])
events = []

async def pipe(reader, writer):
    try:
        while chunk := await reader.read(16384):
            writer.write(chunk)
            await writer.drain()
        if writer.can_write_eof(): writer.write_eof()
    except (ConnectionError, OSError):
        pass

async def echo(reader, writer):
    try:
        await pipe(reader, writer)
    finally:
        writer.close()

async def proxy(reader, writer, kind):
    try:
        if kind == 'socks5':
            assert await reader.readexactly(3) == b'\x05\x01\x00'
            # Deliberately fragment the greeting and tunnel reply.
            for part in (b'\x05', b'\x00'):
                writer.write(part); await writer.drain(); await asyncio.sleep(.005)
            ver, cmd, reserved, atyp = await reader.readexactly(4)
            assert (ver, cmd, reserved) == (5, 1, 0)
            host = str(ipaddress.ip_address(await reader.readexactly(4 if atyp == 1 else 16)))
            port = int.from_bytes(await reader.readexactly(2), 'big')
        else:
            head = await reader.readuntil(b'\r\n\r\n')
            method, authority, version = head.split(b'\r\n', 1)[0].decode().split()
            assert method == 'CONNECT' and version == 'HTTP/1.1'
            host, port = authority.rsplit(':', 1); host = host.strip('[]'); port = int(port)
        assert host in ('198.51.100.42', '2001:db8::42') and port == 19090
        events.append({'kind':kind, 'target':host, 'port':port})
        output.write_text(json.dumps(events))
        if kind == 'deny':
            writer.write(b'HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n')
            await writer.drain(); return
        if kind == 'stall':
            await asyncio.sleep(12); return
        upstream, remote = await asyncio.open_connection('127.0.0.1', port)
        if kind == 'socks5':
            # Domain-form BND.ADDR exercises a different reply path from the request.
            reply = b'\x05\x00\x00\x03\x09localhost\x00\x00'
        else:
            reply = b'HTTP/1.1 200 Connection established\r\nX-Fixture: fragmented\r\n\r\n'
        for part in (reply[:1], reply[1:4], reply[4:]):
            writer.write(part); await writer.drain(); await asyncio.sleep(.005)
        try:
            await asyncio.gather(pipe(reader,remote), pipe(upstream,writer))
        finally:
            remote.close()
    except (ConnectionError, OSError, asyncio.IncompleteReadError):
        pass
    finally:
        writer.close()

async def main():
    bind = '0.0.0.0' if '--lan' in sys.argv else '127.0.0.1'
    servers = [await asyncio.start_server(echo,'127.0.0.1',19090)]
    for port, kind in [(19091,'http'),(19092,'socks5'),(19093,'deny'),(19094,'stall')]:
        servers.append(await asyncio.start_server(lambda r,w,k=kind:proxy(r,w,k),bind,port))
    print('ready',flush=True)
    await asyncio.gather(*(s.serve_forever() for s in servers))
asyncio.run(main())
