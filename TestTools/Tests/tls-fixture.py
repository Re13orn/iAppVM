#!/usr/bin/env python3
"""Self-owned TLS/mTLS fixtures: loopback by default, explicit --lan IP for device tests."""
import asyncio
import json
from pathlib import Path
import ssl
import subprocess
import sys

folder = Path(sys.argv[1])
folder.mkdir(parents=True, exist_ok=True)
def openssl(*args):
    subprocess.run(['openssl', *args], cwd=folder, check=True, capture_output=True)

if not (folder / 'client.p12').exists():
    openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '2', '-subj', '/CN=iAppVM TLS Test CA')
    for name in ('server', 'client'):
        openssl('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', name + '.key', '-out', name + '.csr', '-subj', '/CN=localhost' if name == 'server' else '/CN=iAppVM synthetic client')
        lan_ip = sys.argv[sys.argv.index('--lan') + 1] if '--lan' in sys.argv else None
        import ipaddress
        if lan_ip: ipaddress.ip_address(lan_ip)
        ext = ('subjectAltName=DNS:localhost,IP:127.0.0.1' + (',IP:' + lan_ip if lan_ip else '') + '\nextendedKeyUsage=serverAuth\n') if name == 'server' else 'extendedKeyUsage=clientAuth\n'
        (folder / (name + '.ext')).write_text(ext)
        openssl('x509', '-req', '-in', name + '.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-out', name + '.pem', '-days', '2', '-extfile', name + '.ext')
        openssl('x509', '-in', name + '.pem', '-outform', 'DER', '-out', name + '.der')
    openssl('x509', '-in', 'ca.pem', '-outform', 'DER', '-out', 'ca.der')
    openssl('pkcs12', '-export', '-inkey', 'client.key', '-in', 'client.pem', '-certfile', 'ca.pem', '-out', 'client.p12', '-passout', 'pass:fixture-only')

observed = []
async def handle(reader, writer):
    try:
        headers = await reader.readuntil(b'\r\n\r\n')
        peer = writer.get_extra_info('peercert')
        observed.append({'clientCertificatePresented': bool(peer), 'requestLine': headers.split(b'\r\n', 1)[0].decode('ascii', 'replace'), 'requestModifiedByBurp': b'X-iAppVM-Burp: request-modified'.lower() in headers.lower()})
        (folder / 'server-observed.json').write_text(json.dumps(observed, indent=2))
        body = b'{"fixture":"tls-analysis","ok":true}'
        writer.write(b'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
        await writer.drain()
    finally:
        writer.close()

async def main():
    servers = []
    for port, mtls in ((19443, False), (19444, True)):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(folder / 'server.pem', folder / 'server.key')
        ctx.load_verify_locations(folder / 'ca.pem')
        if mtls:
            ctx.verify_mode = ssl.CERT_REQUIRED
        servers.append(await asyncio.start_server(handle, '0.0.0.0' if '--lan' in sys.argv else '127.0.0.1', port, ssl=ctx))
    print('ready', flush=True)
    await asyncio.gather(*(s.serve_forever() for s in servers))
asyncio.run(main())
