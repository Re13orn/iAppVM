#!/usr/bin/env python3
"""Sign new iOSVM imports with the Mac Keychain identity and return them over USB."""
import argparse
import json
import pathlib
import plistlib
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
QUEUE = "Documents/iOSVM/SigningRequests"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", type=pathlib.Path, default=ROOT / "build/device/signing-settings.json")
    parser.add_argument("--watch", action="store_true", help="Keep signing new imports until Ctrl+C")
    args = parser.parse_args()
    settings = json.loads(args.settings.read_text())
    device, identity, host = (settings[key] for key in ("device", "identity", "host_bundle_id"))
    base = ["--device", device, "--domain-type", "appDataContainer", "--domain-identifier", host]
    attempted = set()

    def transfer(direction, source, destination):
        subprocess.run(["xcrun", "devicectl", "device", "copy", direction, *base,
                        "--source", str(source), "--destination", str(destination), "--quiet"],
                       check=True, capture_output=True, timeout=180)

    def write_request(request, directory):
        path = directory / (request["guest"] + ".json")
        path.write_text(json.dumps(request, indent=2) + "\n")
        transfer("to", path, QUEUE + "/" + path.name)

    print("自动签名服务已启动。保持 USB 连接；手机导入 IPA 后会自动处理。Ctrl+C 停止。", flush=True)
    while True:
        with tempfile.TemporaryDirectory(prefix="iosvm-sign-") as temporary:
            work = pathlib.Path(temporary)
            try:
                transfer("from", QUEUE, work / "requests")
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                if not args.watch:
                    print("未发现签名队列。请先在手机导入 IPA，并确认手机已连接且解锁。", flush=True)
                if args.watch:
                    time.sleep(3)
                    continue
                return
            for request_path in sorted((work / "requests").glob("*.json")):
                request = json.loads(request_path.read_text())
                if request.get("state") not in {"pending", "signing"} or request.get("id") in attempted:
                    continue
                guest = request.get("guest", "")
                if pathlib.PurePath(guest).name != guest or not guest.endswith(".app") or not guest or request_path.name != guest + ".json":
                    print("跳过无效签名请求。", flush=True)
                    continue
                attempted.add(request["id"])
                try:
                    if request.get("version") != 1 or request.get("shared"):
                        raise ValueError("此 Mac 签名服务只处理当前宿主的本地导入 App")
                    print("正在签名：" + guest, flush=True)
                    app = work / guest
                    transfer("from", "Documents/Applications/" + guest, app)
                    config = plistlib.loads((app / "LCAppInfo.plist").read_bytes())
                    info = plistlib.loads((app / "Info.plist").read_bytes())
                    if config.get("IOSVMSigningGeneration") != request["id"] or info.get("CFBundleIdentifier") != request["bundleID"]:
                        raise ValueError("导入内容已变化，请在手机重新请求签名")
                    # Never allow downloaded symlinks to direct codesign outside this temporary bundle.
                    if any(path.is_symlink() for path in app.rglob("*")):
                        raise ValueError("App 内含符号链接，需要单独检查后签名")
                    folder = request.get("tweakFolder", "")
                    if folder and pathlib.PurePath(folder).name != folder:
                        raise ValueError("插件目录名无效")
                    command = ["python3", str(ROOT / "scripts/sign-guest.py"), str(app), "--identity", identity,
                               "--host-bundle-id", host, "--tweak-folder", folder or "iOSVM-Test"]
                    subprocess.run(command, check=True, capture_output=True, timeout=180)
                    # An import can be replaced while it is being signed; do not overwrite a newer request.
                    latest_path = work / "latest-request.json"
                    transfer("from", QUEUE + "/" + request_path.name, latest_path)
                    if json.loads(latest_path.read_text()).get("id") != request["id"]:
                        print("检测到新导入，跳过旧签名结果：" + guest, flush=True)
                        continue
                    current_config_path = work / "current-config.plist"
                    transfer("from", "Documents/Applications/" + guest + "/LCAppInfo.plist", current_config_path)
                    current_config = plistlib.loads(current_config_path.read_bytes())
                    if current_config.get("IOSVMSigningGeneration") != request["id"]:
                        print("检测到新 App 内容，跳过旧结果：" + guest, flush=True)
                        continue
                    # Preserve settings the user changed while the imported code was being signed.
                    current_config.update(IOSVMExternallySigned=True, IOSVMNeedsExternalSigning=False,
                                          dontSign=True, isJITNeeded=False)
                    (app / "LCAppInfo.plist").write_bytes(plistlib.dumps(current_config))
                    subprocess.run(["codesign", "--force", "--sign", identity, "--identifier", host, str(app)],
                                   check=True, capture_output=True, timeout=60)
                    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                                   check=True, capture_output=True, timeout=60)
                    transfer("to", app, "Documents/Applications/" + guest)
                    request["state"] = "ready"
                    write_request(request, work)
                    print("签名完成，可在手机启动：" + guest, flush=True)
                except Exception as error:
                    request["state"] = "error"
                    # Command output may contain private paths; never persist device file contents.
                    request["error"] = str(error)
                    try:
                        latest_error = work / "latest-error-request.json"
                        transfer("from", QUEUE + "/" + request_path.name, latest_error)
                        if json.loads(latest_error.read_text()).get("id") == request["id"]:
                            write_request(request, work)
                    except Exception:
                        pass
                    print("签名失败：" + guest + " — " + str(error), flush=True)
        if not args.watch:
            return
        time.sleep(3)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n自动签名服务已停止。", flush=True)
