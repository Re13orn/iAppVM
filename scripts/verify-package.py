#!/usr/bin/env python3
"""Check the actual IPA, including the generated probe and signing metadata."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import zipfile

package = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="iosvm-package-check-") as directory:
    with zipfile.ZipFile(package) as archive:
        assert archive.testzip() is None, "Corrupt ZIP entry"
        archive.extractall(directory)
    payload = pathlib.Path(directory) / "Payload"
    apps = [path for path in payload.glob("*.app") if path.is_dir()]
    assert len(apps) == 1, "Expected exactly one application bundle in Payload"
    app = apps[0]
    probe = app / "iOSVMProbe.bundle/iOSVMProbe.dylib"
    assert probe.is_file(), "Built-in probe missing from IPA"
    gadget = app / "iOSVMFrida.bundle/FridaGadget.dylib"
    assert gadget.is_file(), "Built-in Frida Gadget missing from IPA"
    assert plistlib.loads((gadget.parent / "Info.plist").read_bytes())["CFBundleVersion"] == "17.7.3"
    assert subprocess.run(["lipo", "-archs", str(gadget)], check=True, capture_output=True, text=True).stdout.strip() == "arm64"
    for license_name in ("COPYING", "COPYING.LIB", "COPYING.frida-core"):
        assert (gadget.parent / license_name).is_file(), "Missing Gadget license text"
    assert not (gadget.parent / "FridaGadget.config").exists(), "Never package a shared Gadget token"
    subprocess.run(["codesign", "--verify", "--strict", str(gadget)], check=True)
    hook_sdk = probe.parent / "iOSVMHWHook.dylib"
    assert hook_sdk.is_file(), "Optional hardware hook runtime missing from IPA"
    subprocess.run(["codesign", "--verify", "--strict", str(hook_sdk)], check=True)
    exports = subprocess.run(["nm", "-gU", str(hook_sdk)], check=True, capture_output=True, text=True).stdout
    for symbol in ("IOSVMHWCapacity", "IOSVMHWEnter", "IOSVMHWSetEnabled", "IOSVMHWExit"):
        assert "_" + symbol in exports, "Hook SDK export missing: " + symbol
    probe_info = plistlib.loads((probe.parent / "Info.plist").read_bytes())
    assert probe_info["CFBundlePackageType"] == "BNDL"
    assert not (app / "Frameworks/SideStoreSupport.framework").exists()
    assert (app / "Frameworks/TweakLoader.dylib").is_file()
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    signature = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True)
    entitlements = plistlib.loads(signature.stdout)
    assert entitlements["get-task-allow"] is True
    assert len(entitlements["keychain-access-groups"]) == 128
    # Pure window-signing profiles can omit the legacy shared App Group while
    # still providing the extension-specific profile used by LiveProcess.
    assert len(entitlements.get("com.apple.security.application-groups", [])) in (0, 2)
    assert "$(" not in repr(entitlements), "Unexpanded signing metadata"
    extensions = {path.name for path in (app / "PlugIns").glob("*.appex")}
    assert extensions in (
        {"LiveProcess.appex"},
        {"LaunchAppExtension.appex", "LiveProcess.appex", "ShareExtension.appex"},
    ), "Unexpected extension set: " + repr(sorted(extensions))
    print("PASS: IPA integrity, bundled Frida Gadget/licenses, probe and hook SDK, TweakLoader, nested signatures, entitlement metadata")
