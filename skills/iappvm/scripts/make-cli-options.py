#!/usr/bin/env python3
"""Create a private Frida CLI -O file from an iAppVM listen config; never connect."""
import argparse
import json
import os
import pathlib
import shlex


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=pathlib.Path, required=True)
    parser.add_argument('--address', required=True, help='Computer endpoint of the USB forwarder')
    parser.add_argument('--output', type=pathlib.Path, required=True, help='New private options file; will not overwrite')
    args = parser.parse_args()
    try:
        with args.config.open('rb') as stream:
            raw = stream.read(65537)
        if len(raw) > 65536:
            raise ValueError('Config exceeds 64 KiB')
        config = json.loads(raw)
        interaction = config.get('interaction', {})
        if interaction.get('type') != 'listen':
            raise ValueError('Requires listen mode; disable automatic scripts and restart the target first')
        token = interaction.get('token')
        if not isinstance(token, str) or not token or '\0' in token:
            raise ValueError('Missing or invalid authentication token')
        host, port = args.address.rsplit(':', 1)
        if not host or any(c.isspace() for c in host) or not 1 <= int(port) <= 65535:
            raise ValueError('Invalid forwarded endpoint')
        text = shlex.join(['--host', args.address, '--token', token]) + '\n'
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(text)
    except FileExistsError:
        parser.error('Output exists; choose a new filename. Existing file was preserved.')
    except (OSError, ValueError, TypeError, AttributeError):
        parser.error('Cannot create options: check config is authenticated listen mode, endpoint, and output permissions. No connection attempted.')
    print('Created private CLI options file. Use frida -O FILE -n Gadget -l SCRIPT; no connection attempted.')


if __name__ == '__main__':
    main()
