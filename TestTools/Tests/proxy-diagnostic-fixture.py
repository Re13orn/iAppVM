#!/usr/bin/env python3
"""No outbound connections: validate diagnostic negotiation and fragment every response."""
import asyncio, sys
async def handle(reader,writer,mode):
    try:
        if mode=='socks5':
            assert await reader.readexactly(3)==b'\x05\x01\x00'
            writer.write(b'\x05');await writer.drain();await asyncio.sleep(.01)
            writer.write(b'\x00');await writer.drain()
            assert await reader.readexactly(5)==b'\x05\x01\x00\x03\x0b'
            assert await reader.readexactly(13)==b'example.com\x01\xbb'
            response=b'\x05\x00\x00\x03\x09localhost\x00\x00'
        else:
            assert (await reader.readuntil(b'\r\n\r\n')).startswith(b'CONNECT example.com:443 HTTP/1.1\r\n')
            if mode=='stall':await asyncio.sleep(10);return
            response=b'HTTP/1.1 407 Authentication required\r\n\r\n' if mode=='deny' else b'HTTP/1.1 200 Connection established\r\n\r\n'
        for byte in response:
            writer.write(bytes([byte]));await writer.drain();await asyncio.sleep(.001)
        await reader.read(1)
    except (asyncio.IncompleteReadError,ConnectionError,OSError):pass
    finally:writer.close()
async def main():
    servers=[]
    for port,mode in [(19191,'http'),(19192,'socks5'),(19193,'deny'),(19194,'stall')]:
        servers.append(await asyncio.start_server(lambda r,w,m=mode:handle(r,w,m),'0.0.0.0' if '--lan' in sys.argv else '127.0.0.1',port))
    print('ready',flush=True)
    await asyncio.gather(*(server.serve_forever() for server in servers))
asyncio.run(main())
