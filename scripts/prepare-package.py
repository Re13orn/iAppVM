#!/usr/bin/env python3
"""Attach ad-hoc signatures and entitlement metadata for later developer re-signing."""
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
app = pathlib.Path(sys.argv[1]).resolve()
entitlement_sources = {
    "LiveContainer.app": root / "entitlements.xml",
    "LiveProcess.appex": root / "LiveProcess/LiveProcess.entitlements",
    "LaunchAppExtension.appex": root / "LaunchAppExtension/LaunchAppExtension.entitlements",
    "ShareExtension.appex": root / "ShareExtension/ShareExtension.entitlements",
}


def sign(path, entitlements=None):
    command = ["/usr/bin/codesign", "--force", "--sign", "-"]
    if entitlements:
        command += ["--entitlements", str(entitlements)]
    subprocess.run(command + [str(path)], check=True)


# Sign nested code before its containing framework / extension / app.
code = [p for p in app.rglob("*") if p.suffix in {".dylib", ".framework", ".appex"}]
for path in sorted(code, key=lambda p: len(p.parts), reverse=True) + [app]:
    source = entitlement_sources.get(path.name)
    if source is None:
        sign(path)
        continue
    info = plistlib.loads((path / "Info.plist").read_bytes())
    replacements = {
        "DEVELOPMENT_TEAM": "AAAAA11111",
        "PRODUCT_BUNDLE_IDENTIFIER": info["CFBundleIdentifier"],
        "AppIdentifierPrefix": "AAAAA11111.",
        "APP_GROUP_SIDESTORE": "group.com.SideStore.SideStore",
        "APP_GROUP_ALTSTORE": "group.com.rileytestut.AltStore",
    }
    text = source.read_text()
    for key, value in replacements.items():
        text = text.replace("$(" + key + ")", value)
    if "$(" in text:
        raise ValueError("Unexpanded entitlement variable in " + str(source))
    # Validate the XML before passing it to codesign.
    plistlib.loads(text.encode())
    prepared = app.parent.parent / (path.name + ".entitlements")
    prepared.write_text(text)
    sign(path, prepared)

subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
