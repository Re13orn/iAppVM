#!/usr/bin/env python3
"""Sign a guest already imported/patched by LiveContainer; never exports a key."""
import argparse
import pathlib
import plistlib
import struct
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("guest", type=pathlib.Path)
parser.add_argument("--identity", required=True)
parser.add_argument("--host-bundle-id", required=True)
parser.add_argument("--tweak-folder", default="iOSVM-Test")
args = parser.parse_args()
app = args.guest.resolve()
info = plistlib.loads((app / "Info.plist").read_bytes())
config_path = app / "LCAppInfo.plist"
config = plistlib.loads(config_path.read_bytes())
assert config.get("LCPatchRevision") == 7, "Import this guest through LiveContainer first"
# Imported IPAs may keep multiple slices; validate the arm64 Mach-O without requiring a thin file.
executable = app / info["CFBundleExecutable"]
with executable.open("rb") as stream:
    header = stream.read(32)
    fat_magic = header[:4]
    if fat_magic in {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca"}:
        endian = ">" if fat_magic[:1] == b"\xca" else "<"
        wide = fat_magic in {b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
        count = struct.unpack_from(endian + "I", header, 4)[0]
        assert 0 < count <= 64, "Invalid fat Mach-O slice count"
        stream.seek(8)
        records = stream.read(count * (32 if wide else 20))
        arm64_offset = None
        for index in range(count):
            cpu, _, offset = struct.unpack_from(endian + ("IIQ" if wide else "III"), records, index * (32 if wide else 20))
            if cpu == 0x0100000C:
                arm64_offset = offset
                break
        assert arm64_offset is not None and arm64_offset + 32 <= executable.stat().st_size, "No valid arm64 slice"
        stream.seek(arm64_offset)
        header = stream.read(32)
    magic, cpu, _, filetype = struct.unpack_from("<IIII", header)
    assert magic == 0xFEEDFACF and cpu == 0x0100000C and filetype == 6, "Expected LC-patched arm64 dylib"
assert pathlib.Path(args.tweak_folder).name == args.tweak_folder, "Use a single tweak folder name"
config.update(IOSVMExternallySigned=True, IOSVMNeedsExternalSigning=False, dontSign=True, isJITNeeded=False, LCTweakFolder=args.tweak_folder)
config_path.write_bytes(plistlib.dumps(config))
code = [p for p in app.rglob("*") if p.suffix in {".dylib", ".framework", ".appex"}]
for path in sorted(code, key=lambda p: len(p.parts), reverse=True) + [app]:
    subprocess.run(["codesign", "--force", "--sign", args.identity, "--identifier", args.host_bundle_id, str(path)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print("Guest signed for external-signing mode:", app)
