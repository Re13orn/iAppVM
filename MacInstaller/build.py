#!/usr/bin/env python3
"""Build a standalone macOS assistant; Xcode/Rust are build-time dependencies only."""
import argparse, json, pathlib, plistlib, shutil, subprocess, sys, zipfile
root=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--skip-ios-build',action='store_true')
args=parser.parse_args()
out=root/'build/MacInstaller'; out.mkdir(parents=True,exist_ok=True)
def run(cmd,**kw): subprocess.run(cmd,check=True,cwd=root,**kw)
if not args.skip_ios_build:
    with (out/'ios-build.log').open('w') as log:
        run(['bash','scripts/build-host.sh'],stdout=log,stderr=subprocess.STDOUT)
run(['cargo','build','--release','--locked','--manifest-path','MacInstaller/Backend/Cargo.toml'])
app=out/'iAppVM 安装助手.app'
# This directory is only our generated build output; never a phone data domain.
if app.exists(): shutil.rmtree(app)
mac=app/'Contents/MacOS'; helpers=app/'Contents/Helpers'; resources=app/'Contents/Resources'
for path in (mac,helpers,resources): path.mkdir(parents=True)
run(['swiftc','-parse-as-library','-swift-version','5','-O','-target','arm64-apple-macosx14.0','MacInstaller/App/InstallerApp.swift','-o',str(mac/'iAppVMInstaller')])
shutil.copy2(root/'MacInstaller/Backend/target/release/iappvm-installer-engine',helpers/'iappvm-installer-engine')
run(['swiftc','-O','-target','arm64-apple-macosx14.0','MacInstaller/App/SigningIdentityBridge.swift','-o',str(helpers/'iappvm-signing-identity')])
source=root/'build/DerivedData/Build/Products/Release-iphoneos/LiveContainer.app'
payload=resources/'iAppVM.app';run(['/usr/bin/ditto',str(source),str(payload)])
for path in (payload/'Extensions',payload/'Frameworks/SideStoreSupport.framework'):
    if path.exists(): shutil.rmtree(path)
for path in (payload/'PlugIns').iterdir():
    if path.name!='LiveProcess.appex':
        if path.is_dir(): shutil.rmtree(path)
        else: path.unlink()
# No developer's profile or signing identity is shipped.
for p in list(payload.rglob('embedded.mobileprovision')): p.unlink()
for p in sorted(payload.rglob('_CodeSignature'), key=lambda p:len(p.parts),reverse=True):
    if p.is_dir(): shutil.rmtree(p)
info=plistlib.loads((payload/'Info.plist').read_bytes())
info.update(CFBundleIdentifier='com.iappvm.container',CFBundleDisplayName='iAppVM',CFBundleName='iAppVM',IOSVMTestWindowsEnabled=True,IOSVMInstallerPayloadVersion=1)
(payload/'Info.plist').write_bytes(plistlib.dumps(info))
ext=payload/'PlugIns/LiveProcess.appex/Info.plist'; ei=plistlib.loads(ext.read_bytes());ei['CFBundleIdentifier']='com.iappvm.container.LiveProcess';ext.write_bytes(plistlib.dumps(ei))
# A Mac .app icon, independent of upstream branding.
icon_dir=out/'Installer.iconset';icon_dir.mkdir(exist_ok=True)
# Native SF Symbol rendered by the small AppKit tool; no external design assets.
run(['swift','MacInstaller/render-icon.swift',str(icon_dir)])
run(['iconutil','-c','icns',str(icon_dir),'-o',str(resources/'Installer.icns')])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.iappvm.installer','CFBundleExecutable':'iAppVMInstaller','CFBundleName':'iAppVM 安装助手','CFBundleDisplayName':'iAppVM 安装助手','CFBundleIconFile':'Installer','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication'}))
licenses=resources/'Licenses';licenses.mkdir()
shutil.copy2(root/'LICENSE',licenses/'iAppVM-AGPL-3.0.txt')
# Include the exact crate licenses (with full texts) of all resolved dependencies.
metadata=json.loads(subprocess.check_output(['cargo','metadata','--locked','--format-version','1','--manifest-path','MacInstaller/Backend/Cargo.toml'],cwd=root))
summary=[]
for package in metadata['packages']:
    directory=pathlib.Path(package['manifest_path']).parent
    summary.append({'name':package['name'],'version':package['version'],'license':package.get('license'),'repository':package.get('repository')})
    texts=[p for p in directory.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE','COPYING','NOTICE'))]
    if texts:
        dst=licenses/(package['name']+'-'+package['version']);dst.mkdir(exist_ok=True)
        for p in texts:shutil.copy2(p,dst/p.name)
(licenses/'dependencies.json').write_text(json.dumps(summary,indent=2)+'\n')
shutil.copy2(root/'MacInstaller/README.md',resources/'README.md')
run(['codesign','--force','--sign','-',str(helpers/'iappvm-signing-identity')])
run(['codesign','--force','--sign','-',str(helpers/'iappvm-installer-engine')])
run(['codesign','--force','--sign','-',str(app)])
run(['codesign','--verify','--strict',str(app)])
archive=out/'iAppVM-Installer-0.1.0-arm64.zip'
if archive.exists():archive.unlink()
run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(app),str(archive)])
source_archive=out/'iAppVM-Installer-0.1.0-source.zip'
with zipfile.ZipFile(source_archive,'w',zipfile.ZIP_DEFLATED) as package:
    for path in (root/'MacInstaller').rglob('*'):
        if path.is_file() and not {'target','__pycache__'}.intersection(path.relative_to(root/'MacInstaller').parts):
            package.write(path,str(path.relative_to(root)))
print(app);print(archive);print(source_archive)
