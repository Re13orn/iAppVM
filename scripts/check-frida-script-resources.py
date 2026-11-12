#!/usr/bin/env python3
"""Verify offline script support in an .app or IPA, without extracting user data."""
import hashlib
import json
from pathlib import Path
import sys
import zipfile

path = Path(sys.argv[1])
if path.is_dir():
    def read(name):
        return (path / 'ScriptSupport.bundle' / name).read_bytes()
else:
    archive = zipfile.ZipFile(path)
    roots = [n[:-len('provenance.json')] for n in archive.namelist()
             if n.startswith('Payload/') and n.endswith('.app/ScriptSupport.bundle/provenance.json')]
    assert len(roots) == 1, 'Missing or ambiguous script support resource bundle'
    def read(name):
        return archive.read(roots[0] + name)

provenance = json.loads(read('provenance.json'))
for name, expected in provenance['sha256'].items():
    assert hashlib.sha256(read(name)).hexdigest() == expected, 'Resource hash mismatch: ' + name
for name in ('acorn.js', 'objc.js', 'analyze.js', 'phone-logger.js', 'LICENSE.acorn', 'COPYING.frida-tools', 'COPYING.LIB'):
    assert read(name), 'Empty script support resource: ' + name
print('PASS: offline parser, ObjC bridge, analyzer, provenance and licenses present and verified')
