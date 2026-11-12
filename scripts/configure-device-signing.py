#!/usr/bin/env python3
"""Provision only the configured iOSVM signing identity into the device keychain over USB."""
import argparse
import json
import pathlib
import plistlib
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', help='Target device UDID or CoreDevice identifier; defaults to signing-settings.json')
args = parser.parse_args()

root = pathlib.Path(__file__).resolve().parents[1]
settings = json.loads((root / 'build/device/signing-settings.json').read_text())
if args.device:
    settings['device'] = args.device
exporter = root / 'build/device/export-signing-identity'
source = root / 'scripts/export-signing-identity.swift'
if not exporter.exists() or exporter.stat().st_mtime < source.stat().st_mtime:
    subprocess.run(['swiftc', str(source), '-o', str(exporter)], check=True)
base = ['--device', settings['device'], '--domain-type', 'appDataContainer', '--domain-identifier', settings['host_bundle_id']]
with tempfile.TemporaryDirectory(prefix='iosvm-signing-') as temporary:
    work = pathlib.Path(temporary)
    setup = work / 'setup.plist'
    try:
        # macOS may show its normal Keychain permission dialog for this exact private key.
        subprocess.run([str(exporter), settings['identity'], settings['host_bundle_id'], str(setup)], check=True)
        request_id = plistlib.loads(setup.read_bytes())['id']
        subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'to', *base, '--source', str(setup),
                        '--destination', 'Library/iOSVM-signing-setup.plist', '--quiet'], check=True, timeout=30)
    finally:
        setup.unlink(missing_ok=True)
    subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', settings['device'],
                    '--terminate-existing', '--quiet', settings['host_bundle_id'], '--', '-selected', 'ui'], check=True, timeout=30)
    for attempt in range(15):
        status = work / 'status.json'
        copied = subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', *base, '--source',
            'Library/iOSVM-signing-status.json', '--destination', str(status), '--quiet'], capture_output=True, timeout=15)
        if copied.returncode == 0:
            result = json.loads(status.read_text())
            if result.get('id') != request_id:
                time.sleep(1)
                continue
            if result.get('state') == 'ready':
                print('手机签名已配置，证书保存在设备钥匙串中。新 IPA 可直接在手机签名，无需运行电脑签名服务。')
                break
            raise SystemExit(result.get('message', '设备证书配置失败，请检查手机。'))
        time.sleep(1)
    else:
        raise SystemExit('手机尚未完成配置，请解锁并打开 iOSVM。一次性配置将在读取后删除。')
