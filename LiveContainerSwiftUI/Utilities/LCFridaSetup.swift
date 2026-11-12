import Foundation
import Security

enum LCFridaSetup {
    static let library = "FridaGadget.dylib"
    static let configuration = "FridaGadget.config"

    static func folder(for app: LCAppInfo) -> URL? {
        guard let name = app.tweakFolder, !name.isEmpty else { return nil }
        return (app.isShared ? LCPath.lcGroupTweakPath : LCPath.tweakPath).appendingPathComponent(name)
    }

    static func enabled(_ app: LCAppInfo) -> Bool {
        guard let folder = folder(for: app) else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(library).path)
    }

    /// Each app gets its own plugin folder. Existing plugins and dependency rules are preserved.
    static func prepare(_ app: LCAppInfo) async throws {
        guard !app.is32bit else { throw "Frida Gadget 仅支持此构建中的 arm64 App。" }
        guard !(app.info()["LCTweakLoaderCantInject"] as? Bool ?? false), !app.dontInjectTweakLoader else {
            throw "此 App 尚未成功注入 TweakLoader，无法自动加载 Gadget。"
        }
        guard let bundle = Bundle.main.url(forResource: "iOSVMFrida", withExtension: "bundle") else {
            throw "此宿主未包含 Frida Gadget，请更新 iAppVM。"
        }
        let fm = FileManager.default
        let base = app.isShared ? LCPath.lcGroupTweakPath : LCPath.tweakPath
        let storageRoot = app.isShared ? LCPath.lcGroupDocPath : LCPath.docPath
        do {
            // Updates can retain a Tweaks tree whose directory owner no longer matches this app process.
            // Repair by publishing an owned copy and retaining the legacy directory as a hidden backup.
            try LCManagedDirectory.ensureWritableChain(base, inside: storageRoot)
        } catch {
            throw "Tweaks 目录无法写入或自动修复：\(error.localizedDescription)"
        }
        var location = try LCFridaWorkspace.locate(base: base, bundle: app.relativeBundlePath, selected: app.tweakFolder)
        if location.reuseExisting,
           let owner = try LCFridaScriptStore.selection(folder: location.destination).owner,
           owner != app.relativeBundlePath {
            let unique = location.name + "-" + UUID().uuidString
            location = LCFridaWorkspace.Location(name: unique, destination: base.appendingPathComponent(unique), source: location.destination)
        }
        if fm.fileExists(atPath: location.destination.path) {
            do { try LCManagedDirectory.ensureWritableChain(location.destination, inside: storageRoot) }
            catch { throw "Frida 插件目录无法写入或自动修复：\(error.localizedDescription)" }
        }
        let name = location.name
        let finalFolder = location.destination
        let moving = !location.reuseExisting
        let target = moving ? base.appendingPathComponent(".frida-setup-" + UUID().uuidString) : finalFolder
        defer { if moving { try? fm.removeItem(at: target) } }
        if moving {
            if let old = location.source {
                try fm.copyItem(at: old, to: target)
            } else {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            }
        }
        let destination = target.appendingPathComponent(library)
        if moving, fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        if !fm.fileExists(atPath: destination.path) {
            try fm.copyItem(at: bundle.appendingPathComponent(library), to: destination)
        }
        let configURL = target.appendingPathComponent(configuration)
        if moving || !fm.fileExists(atPath: configURL.path) {
            var bytes = [UInt8](repeating: 0, count: 24)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw "无法生成 Frida 连接口令。"
            }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            let port = try availablePort()
            let config: [String: Any] = ["interaction": ["type": "listen", "address": "127.0.0.1", "port": port,
                                                           "on_load": "resume", "token": token],
                                       "runtime": "qjs", "code_signing": "required"]
            try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: configURL, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        let hasManifest = fm.fileExists(atPath: target.appendingPathComponent(LCFridaScriptStore.manifestName).path)
        var selection = try LCFridaScriptStore.selection(folder: target)
        if selection.owner != app.relativeBundlePath || !hasManifest || moving {
            if moving && selection.owner != app.relativeBundlePath {
                selection.automatic = false; selection.scripts = []; selection.computerScripts = []; selection.fingerprints = [:]
            }
            selection.owner = app.relativeBundlePath
            if try (moving || !hasManifest) && LCFridaScriptStore.digest(contentsOf: destination) == LCFridaScriptStore.digest(contentsOf: bundle.appendingPathComponent(library)) {
                selection.gadgetVersion = LCFridaVersions.builtin.version
                selection.gadgetID = "builtin"
            }
            try LCFridaScriptStore.apply(selection, folder: target)
        }
        // Declare Gadget as a prerequisite so plugin constructors can be observed in wait mode.
        let manifestURL = target.appendingPathComponent("iOSVMPlugins.json")
        var manifest: [String: Any] = ["version": 1, "plugins": []]
        if fm.fileExists(atPath: manifestURL.path) {
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
                  existing["version"] as? Int == 1, existing["plugins"] is [[String: Any]] else {
                throw "插件依赖清单格式错误，请修复 iOSVMPlugins.json 后重试。"
            }
            manifest = existing
        }
        var plugins = manifest["plugins"] as? [[String: Any]] ?? []
        let names = try fm.contentsOfDirectory(atPath: target.path).filter { $0.hasSuffix(".dylib") || $0.hasSuffix(".framework") }
        for file in names where file != library {
            if let index = plugins.firstIndex(where: { $0["file"] as? String == file }) {
                var dependencies = plugins[index]["requires"] as? [String] ?? []
                if !dependencies.contains(library) { dependencies.append(library) }
                plugins[index]["requires"] = dependencies
            } else { plugins.append(["file": file, "requires": [library]]) }
        }
        // Gadget itself must not depend on the other libraries.
        plugins.removeAll { $0["file"] as? String == library }
        plugins.insert(["file": library, "requires": []], at: 0)
        manifest["plugins"] = plugins
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL, options: .atomic)
        try await LCUtils.signTweaks(tweakFolderUrl: target, force: false)
        if moving { try fm.moveItem(at: target, to: finalFolder) }
        app.tweakFolder = name
        app.dontLoadTweakLoader = false
        app.info()["IOSVMFridaEnabled"] = true
        app.save()
        let saved = NSDictionary(contentsOfFile: app.bundlePath() + "/LCAppInfo.plist")
        guard saved?["LCTweakFolder"] as? String == name else {
            throw "Gadget 已准备，但 App 的插件目录设置未能保存。请重试；原有插件文件已保留。"
        }
    }

    @MainActor static func switchVersion(_ version: LCFridaVersions.Version, app: LCAppInfo) async throws {
        guard let previous = folder(for: app) else { throw "请先准备 Gadget。" }
        guard !IOSVMProcessRegistry.shared.isBundleBusy(app.relativeBundlePath) else { throw "请先关闭目标 App。" }
        let source = try LCFridaVersions.library(version)
        let base = previous.deletingLastPathComponent(), fm = FileManager.default
        let stage = base.appendingPathComponent(".frida-version-" + UUID().uuidString)
        let name = "iOSVM-Frida-" + String(app.relativeBundlePath.prefix(120)) + "-" + UUID().uuidString
        let final = base.appendingPathComponent(name)
        defer { LCManagedDirectory.cleanup(stage) }
        try fm.copyItem(at: previous, to: stage)
        try fm.removeItem(at: stage.appendingPathComponent(library))
        try fm.copyItem(at: source, to: stage.appendingPathComponent(library))
        var selection = try LCFridaScriptStore.selection(folder: stage)
        if selection.owner != app.relativeBundlePath { selection.automatic = false; selection.scripts = []; selection.computerScripts = []; selection.fingerprints = [:] }
        selection.owner = app.relativeBundlePath
        selection.gadgetVersion = version.version; selection.gadgetID = version.id
        try LCFridaScriptStore.apply(selection, folder: stage)
        try await LCUtils.signTweaks(tweakFolderUrl: stage, force: true)
        guard !IOSVMProcessRegistry.shared.isBundleBusy(app.relativeBundlePath) else { throw "目标在准备期间已启动，版本切换已取消。" }
        try fm.moveItem(at: stage, to: final)
        app.tweakFolder = name
        app.info()["IOSVMNeedsExternalSigning"] = true
        app.info()["IOSVMDeviceSigned"] = false
        app.info()["IOSVMExternallySigned"] = false
        app.save()
        guard NSDictionary(contentsOfFile: app.bundlePath() + "/LCAppInfo.plist")?["LCTweakFolder"] as? String == name else {
            app.tweakFolder = previous.lastPathComponent
            app.save()
            throw "新版本已签名，但目录关联保存失败。原版本目录仍保留。"
        }
    }

    // Multiple LiveProcess windows may run concurrently; each Gadget needs a distinct device port.
    private static func availablePort() throws -> Int {
        let fm = FileManager.default
        var used = Set<Int>()
        for root in Set([LCPath.tweakPath, LCPath.lcGroupTweakPath]) {
            for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                guard (try? fm.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) == .typeDirectory else { continue }
                let url = folder.appendingPathComponent(configuration)
                guard let attrs = try? fm.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
                      ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) < 65536,
                      let data = try? Data(contentsOf: url),
                      let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let interaction = config["interaction"] as? [String: Any], let port = interaction["port"] as? Int else { continue }
                used.insert(port)
            }
        }
        guard let port = (27042...27999).first(where: { !used.contains($0) }) else { throw "Frida 调试端口已用尽，请移除不再使用的调试目录。" }
        return port
    }

    static func config(_ app: LCAppInfo) throws -> [String: Any] {
        guard let folder = folder(for: app),
              let config = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(configuration))) as? [String: Any] else {
            throw "尚未配置 Frida Gadget。"
        }
        return config
    }

    static func setWait(_ wait: Bool, app: LCAppInfo) throws {
        var config = try config(app)
        var interaction = config["interaction"] as? [String: Any] ?? [:]
        guard interaction["type"] as? String == "listen" else { throw "自动脚本模式不使用等待电脑连接；请先切换到电脑连接模式。" }
        interaction["on_load"] = wait ? "wait" : "resume"
        config["interaction"] = interaction
        let url = folder(for: app)!.appendingPathComponent(configuration)
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func requestSigning(_ app: LCAppInfo) throws {
        let requestID = UUID().uuidString
        app.info()["IOSVMSigningGeneration"] = requestID
        app.info()["IOSVMNeedsExternalSigning"] = true
        app.info()["IOSVMExternallySigned"] = false
        app.info()["IOSVMDeviceSigned"] = false
        app.save()
        let queue = LCPath.docPath.appendingPathComponent("iOSVM/SigningRequests")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        let request: [String: Any] = ["version": 1, "id": requestID, "state": "pending", "guest": app.relativeBundlePath!,
                                      "bundleID": app.bundleIdentifier()!, "tweakFolder": app.tweakFolder ?? "", "shared": app.isShared]
        try JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted, .sortedKeys])
            .write(to: queue.appendingPathComponent(app.relativeBundlePath + ".json"), options: .atomic)
    }
}
