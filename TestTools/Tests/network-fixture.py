#!/usr/bin/env python3
"""Loopback-only HTTP target and HTTP CONNECT / SOCKS5 proxies for transport tests."""
import asyncio
import json
from pathlib import Path
import sys
import ssl
import subprocess

events = []
output = Path(sys.argv[1])

async def tunnel(reader, writer, host, port, kind):
    # The test fixture is intentionally limited to its own synthetic target.
    public_probe = host == "example.com" and port == 443
    if not public_probe and (host not in ("127.0.0.1", "localhost", "iosvm-fixture.test") or port not in (18990, 18993)):
        raise ValueError("unexpected target")
    remote_reader, remote_writer = await asyncio.open_connection(host if public_probe else "127.0.0.1", port)
    events.append({"proxy": kind, "host": host, "port": port, "peer": writer.get_extra_info("peername")[0]})
    output.write_text(json.dumps(events, indent=2))
    async def copy(source, destination):
        try:
            while chunk := await source.read(65536):
                destination.write(chunk)
                await destination.drain()
        finally:
            destination.close()
    await asyncio.gather(copy(reader, remote_writer), copy(remote_reader, writer), return_exceptions=True)

async def http_proxy(reader, writer):
    try:
        head = await reader.readuntil(b"\r\n\r\n")
        method, target, _ = head.split(b"\r\n", 1)[0].decode().split(" ")
        if method != "CONNECT": raise ValueError(method)
        host, port = target.rsplit(":", 1)
        writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await writer.drain()
        await tunnel(reader, writer, host, int(port), "http")
    except Exception:
        writer.close()

async def socks_proxy(reader, writer):
    try:
        version, count = await reader.readexactly(2)
        assert version == 5
        assert 0 in await reader.readexactly(count)
        writer.write(b"\x05\x00"); await writer.drain()
        version, command, _, address_type = await reader.readexactly(4)
        assert version == 5 and command == 1
        if address_type == 1:
            host = ".".join(str(x) for x in await reader.readexactly(4))
        elif address_type == 3:
            count = (await reader.readexactly(1))[0]
            host = (await reader.readexactly(count)).decode()
        else: raise ValueError(address_type)
        port = int.from_bytes(await reader.readexactly(2), "big")
        writer.write(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00"); await writer.drain()
        await tunnel(reader, writer, host, port, "socks5")
    except Exception:
        writer.close()

async def target(reader, writer):
    try:
        head = await reader.readuntil(b"\r\n\r\n")
        first = head.split(b"\r\n", 1)[0]
        if b"/redirect " in first:
            writer.write(b"HTTP/1.1 302 Found\r\nLocation: /echo\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        else:
            for line in head.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    await reader.readexactly(int(line.split(b":", 1)[1]))
            body = b"x" * (100 * 1024) if b"/large " in first else b'{"fixture":"iosvm-network","ok":true}'
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
        await writer.drain()
    finally:
        writer.close()

async def main():
    cert, key = output.parent / "fixture-cert.pem", output.parent / "fixture-key.pem"
    if not cert.exists():
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=iosvm-fixture.test"], check=True, capture_output=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
    bind = "0.0.0.0" if "--lan" in sys.argv else "127.0.0.1"
    servers = [await asyncio.start_server(handler, bind, port) for handler, port in ((target, 18990), (http_proxy, 18991), (socks_proxy, 18992))]
    servers.append(await asyncio.start_server(target, bind, 18993, ssl=context))
    print("fixture ready", flush=True)
    await asyncio.gather(*(server.serve_forever() for server in servers))

asyncio.run(main())
