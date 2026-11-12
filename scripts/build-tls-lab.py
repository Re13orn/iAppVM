#!/usr/bin/env python3
"""Build the synthetic, ad-hoc TLS Lab IPA for normal import into iAppVM.
Start tls-fixture.py FIXTURE --lan MAC_IP first. Nothing is installed by this script.
"""
import argparse, base64, hashlib, ipaddress, json, plistlib, shutil, subprocess, tempfile
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('fixture',type=Path); p.add_argument('host',type=ipaddress.ip_address); p.add_argument('output',type=Path)
a=p.parse_args(); root=Path(__file__).resolve().parent.parent
fixture=a.fixture.resolve(); output=a.output.resolve(); output.parent.mkdir(parents=True,exist_ok=True)
def run(*args): return subprocess.check_output([str(v) for v in args])
sdk=run('xcrun','--sdk','iphoneos','--show-sdk-path').decode().strip()
with tempfile.TemporaryDirectory(prefix='iosvm-tls-lab-') as temporary:
    stage=Path(temporary); app=stage/'Payload'/'TLSLab.app'; app.mkdir(parents=True)
    resources=app/'TLSFixture'; resources.mkdir()
    for name in ('ca.der','server.der','client.p12'): shutil.copy2(fixture/name,resources/name)
    shutil.copy2(fixture/'server.der',resources/'certificate-without-extension')
    (resources/'endpoint.json').write_text(json.dumps({'host':str(a.host)}))
    public=run('openssl','x509','-in',fixture/'server.pem','-pubkey','-noout')
    spki=subprocess.run(['openssl','pkey','-pubin','-outform','DER'],input=public,capture_output=True,check=True).stdout
    info={'CFBundleIdentifier':'dev.iosvm.tlslab','CFBundleExecutable':'TLSLab','CFBundleDisplayName':'TLS Lab','CFBundleName':'TLS Lab','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1','CFBundleVersion':'2','MinimumOSVersion':'15.0','LSRequiresIPhoneOS':True,'UIDeviceFamily':[1,2],'UILaunchScreen':{},'NSLocalNetworkUsageDescription':'仅连接自有局域网 TLS 测试服务器。','NSAppTransportSecurity':{'NSPinnedDomains':{'untriggered.example.test':{'NSPinnedLeafIdentities':[{'SPKI-SHA256-BASE64':base64.b64encode(hashlib.sha256(spki).digest()).decode()}]}}}}
    (app/'Info.plist').write_bytes(plistlib.dumps(info))
    run('xcrun','clang','-isysroot',sdk,'-target','arm64-apple-ios15.0','-fobjc-arc','-fblocks','-framework','UIKit','-framework','Foundation','-framework','Security',root/'TestTools/TLSLab/main.m','-o',app/'TLSLab')
    run('codesign','--force','--sign','-',app)
    run('ditto','-c','-k','--keepParent',stage/'Payload',output)
print(output)
