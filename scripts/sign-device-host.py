#!/usr/bin/env python3
"""Sign the prototype, optionally retaining a separately provisioned LiveProcess extension."""
import argparse
import datetime
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--profile", type=pathlib.Path, required=True)
parser.add_argument("--identity", required=True)
parser.add_argument("--udid", required=True)
parser.add_argument("--test-windows", action="store_true", help="Require and enable the LiveProcess test-window extension")
parser.add_argument("--liveprocess-profile", type=pathlib.Path, help="Development profile for HOST_BUNDLE_ID.LiveProcess")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
source = root / "build/DerivedData/Build/Products/Release-iphoneos/LiveContainer.app"
output = root / "build/device/iOSVM.app"


def decode(path):
    result = subprocess.run(["security", "cms", "-D", "-i", str(path)], check=True, capture_output=True)
    return plistlib.loads(result.stdout)


def entitlements_for(profile):
    assert profile["ExpirationDate"] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), "Expired profile"
    assert args.udid in profile.get("ProvisionedDevices", []), "Profile does not include target device"
    assert args.identity.upper() in {hashlib.sha1(cert).hexdigest().upper() for cert in profile["DeveloperCertificates"]}, "Certificate not permitted by profile"
    entitlements = dict(profile["Entitlements"])
    assert entitlements.get("get-task-allow"), "A development profile is required"
    app_identifier = entitlements["application-identifier"]
    assert "*" not in app_identifier, "Provide an explicit App ID"
    prefix, bundle_id = app_identifier.split(".", 1)
    assert prefix + ".*" in entitlements.get("keychain-access-groups", []), "Profile must permit the guest keychain groups"
    entitlements["keychain-access-groups"] = [prefix + ".com.kdt.livecontainer.shared" + ("." + str(i) if i else "") for i in range(128)]
    return prefix, bundle_id, entitlements


profile = decode(args.profile)
prefix, bundle_id, entitlements = entitlements_for(profile)
extension_profile_path = args.liveprocess_profile
if args.test_windows and extension_profile_path is None:
    candidates = []
    for directory in (pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
                      pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles"):
        for path in directory.glob("*.mobileprovision"):
            try:
                candidate = decode(path)
                if candidate["Entitlements"].get("application-identifier") == prefix + "." + bundle_id + ".LiveProcess":
                    entitlements_for(candidate)
                    candidates.append((candidate["ExpirationDate"], path))
            except (AssertionError, KeyError, subprocess.CalledProcessError, plistlib.InvalidFileException):
                continue
    if candidates:
        extension_profile_path = max(candidates)[1]
    else:
        raise SystemExit("独立测试窗口需要 " + bundle_id + ".LiveProcess 的开发描述文件。请先运行 scripts/provision-test-windows.sh，或用 --liveprocess-profile 提供文件。现有安装包未更改。")
window_mode = extension_profile_path is not None
extension_profile = None
if window_mode:
    extension_profile = decode(extension_profile_path)
    extension_prefix, extension_bundle_id, extension_entitlements = entitlements_for(extension_profile)
    assert extension_prefix == prefix, "Host and LiveProcess must use the same App ID prefix"
    assert extension_bundle_id == bundle_id + ".LiveProcess", "LiveProcess profile must match the host's child Bundle ID"
    assert (source / "PlugIns/LiveProcess.appex").is_dir(), "Build the host with its LiveProcess extension first"

# All profile validation above happens before replacing any staged output.
if output.exists():
    shutil.rmtree(output)
subprocess.run(["ditto", str(source), str(output)], check=True)
plugins = output / "PlugIns"
if window_mode:
    for child in plugins.iterdir():
        if child.name != "LiveProcess.appex":
            if child.is_dir(): shutil.rmtree(child)
            else: child.unlink()
else:
    shutil.rmtree(plugins, ignore_errors=True)
shutil.rmtree(output / "Extensions", ignore_errors=True)
shutil.rmtree(output / "Frameworks/SideStoreSupport.framework", ignore_errors=True)
info_path = output / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
info.update(CFBundleIdentifier=bundle_id, CFBundleName="iAppVM", CFBundleDisplayName="iAppVM", IOSVMTestWindowsEnabled=window_mode)
info_path.write_bytes(plistlib.dumps(info))
shutil.copyfile(args.profile, output / "embedded.mobileprovision")
entitlements_path = output.parent / "device-entitlements.plist"
entitlements_path.write_bytes(plistlib.dumps(entitlements))
code = [p for p in output.rglob("*") if p.suffix in {".dylib", ".framework"}]
for path in sorted(code, key=lambda p: len(p.parts), reverse=True):
    command = ["codesign", "--force", "--sign", args.identity]
    if path.parent.name in {"iOSVMProbe.bundle", "iOSVMFrida.bundle"} and path.suffix == ".dylib":
        command += ["--identifier", bundle_id]
    subprocess.run(command + [str(path)], check=True)
if window_mode:
    extension = plugins / "LiveProcess.appex"
    extension_info_path = extension / "Info.plist"
    extension_info = plistlib.loads(extension_info_path.read_bytes())
    extension_info["CFBundleIdentifier"] = extension_bundle_id
    extension_info["CFBundleVersion"] = info["CFBundleVersion"]
    extension_info["CFBundleShortVersionString"] = info["CFBundleShortVersionString"]
    extension_info_path.write_bytes(plistlib.dumps(extension_info))
    shutil.copyfile(extension_profile_path, extension / "embedded.mobileprovision")
    extension_entitlements_path = output.parent / "liveprocess-entitlements.plist"
    extension_entitlements_path.write_bytes(plistlib.dumps(extension_entitlements))
    subprocess.run(["codesign", "--force", "--sign", args.identity, "--entitlements", str(extension_entitlements_path), str(extension)], check=True)
subprocess.run(["codesign", "--force", "--sign", args.identity, "--entitlements", str(entitlements_path), str(output)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(output)], check=True)
print("Signed host:", output)
print("Bundle ID:", bundle_id)
print("Test windows:", "enabled" if window_mode else "not included (single-process package)")
print("Profile expiry (UTC):", profile["ExpirationDate"])
(output.parent / "signing-settings.json").write_text(json.dumps({
    "device": args.udid, "identity": args.identity, "host_bundle_id": bundle_id, "test_windows": window_mode
}, indent=2) + "\n")
