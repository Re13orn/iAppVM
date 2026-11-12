import Foundation
import CryptoKit

/// One library, stable UUID identities. Per-app startup snapshots never share writable script files.
enum LCFridaScriptStore {
    struct Script: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var modifiedAt: Date
        var bridgeMode: LCFridaScriptCompatibility.BridgeMode? = nil
        var effectiveBridgeMode: LCFridaScriptCompatibility.BridgeMode { bridgeMode ?? .automatic }
    }
    struct Selection: Codable, Equatable {
        var version = 1
        var owner: String?
        var automatic = false
        var scripts: [UUID] = []
        var computerScripts: [UUID]? = nil
        var phoneScriptNames: [String:String]? = nil
        var phoneExpressions: [String:String]? = nil
        var allowGenericHooks: Bool? = nil
        var captureConsole = true
        var revision = UUID().uuidString
        var fingerprints: [String: String] = [:]
        var listen: [String: String] = [:]
        var gadgetVersion: String?
        var gadgetID: String?
    }
    static var root: URL { LCPath.docPath.appendingPathComponent("iOSVM/Frida/Scripts", isDirectory: true) }
    static let manifestName = "iOSVMFrida.json"
    static let maximumBytes = 8 * 1024 * 1024

    static func failure(_ message: String) -> NSError {
        NSError(domain: "IOSVMFridaScripts", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func isManaged(_ url: URL, inside root: URL) -> Bool {
        let root = root.standardizedFileURL, url = url.standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return false }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        return url.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().appendingPathComponent(relative).standardizedFileURL.path
    }
    static func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Streaming digest for large files (e.g. the multi-MiB Gadget dylib):
    /// keeps at most a 1 MiB slice in memory instead of the whole file.
    static func digest(contentsOf url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        var readError: Error? = nil
        while readError == nil && autoreleasepool(invoking: { () -> Bool in
            let chunk: Data
            do { chunk = try handle.read(upToCount: chunkSize) ?? Data() }
            catch { readError = error; return false }
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        if let readError { throw readError }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func ensureRoot() throws { try LCManagedDirectory.ensureWritableChain(root, inside: LCPath.docPath) }

    static func list() throws -> [Script] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard isManaged(root, inside: LCPath.docPath) else { throw failure("脚本库目录包含链接。") }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent), isManaged(url, inside: LCPath.docPath) else { return nil }
            let metadata = url.appendingPathComponent("metadata.json")
            guard isManaged(metadata, inside: url) else { throw failure("脚本元数据包含链接。") }
            let value = try JSONDecoder().decode(Script.self, from: Data(contentsOf: metadata))
            guard value.id == id else { throw failure("脚本库标识不匹配。") }
            return value
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    static func source(_ script: Script) throws -> String {
        let file = directory(script.id).appendingPathComponent("script.js")
        guard isManaged(file, inside: LCPath.docPath) else { throw failure("脚本路径包含链接。") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize ?? Int.max <= maximumBytes else { throw failure("脚本文件无效或超过 8 MiB。") }
        return try String(contentsOf: file, encoding: .utf8)
    }
    @discardableResult static func save(id: UUID? = nil, name: String, source: String, bridgeMode: LCFridaScriptCompatibility.BridgeMode? = nil) throws -> Script {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 160, !name.contains("\0"),
              source.utf8.count <= maximumBytes, !source.contains("\0") else { throw failure("名称不能为空且最多 160 字节，脚本最多 8 MiB，内容不能含 NUL。") }
        try ensureRoot()
        var script = Script(id: id ?? UUID(), name: name, modifiedAt: Date())
        if let bridgeMode { script.bridgeMode = bridgeMode }
        else if let id, let previous = try list().first(where: { $0.id == id }) { script.bridgeMode = previous.bridgeMode }
        let folder = directory(script.id)
        guard isManaged(folder, inside: folder.deletingLastPathComponent()) else { throw failure("脚本路径包含链接。") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(source.utf8).write(to: folder.appendingPathComponent("script.js"), options: .atomic)
        try JSONEncoder().encode(script).write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent("script.js").path)
        return script
    }
    @discardableResult static func importFile(_ url: URL) throws -> String {
        guard url.pathExtension.lowercased() == "js" else { throw failure("请选择 UTF-8 编码的 .js 文件（编译打包后的 JS 也可以）。") }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= maximumBytes else { throw failure("脚本超过 8 MiB。") }
        let source = try String(contentsOf: url, encoding: .utf8)
        let report = try LCFridaScriptCompatibility.inspect(source)
        try save(name: url.lastPathComponent, source: source)
        return url.lastPathComponent + "：\n" + report.notes.joined(separator: "\n")
    }
    static func remove(_ script: Script) throws {
        let folder = directory(script.id)
        guard isManaged(folder, inside: folder.deletingLastPathComponent()) else { throw failure("脚本路径包含链接。") }
        try FileManager.default.removeItem(at: folder)
    }
    static func selection(folder: URL) throws -> Selection {
        let file = folder.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: file.path) else { return Selection() }
        guard isManaged(file, inside: folder) else { throw failure("启动配置包含链接。") }
        let value = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: file))
        let expressions = value.phoneExpressions ?? [:]
        guard value.version == 1, value.scripts.count <= 32, Set(value.scripts).count == value.scripts.count,
              (value.computerScripts?.count ?? 0) <= 32, Set(value.computerScripts ?? []).count == (value.computerScripts?.count ?? 0),
              expressions.count <= 32,
              expressions.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.utf8.count <= 8192 && !$0.value.contains("\0") })
        else { throw failure("启动脚本配置无效。") }
        return value
    }
    /// Publish a complete generation, then atomically point Gadget at it. Keep the listen identity intact.
    static func apply(_ requested: Selection, folder: URL) throws {
        let fm = FileManager.default
        guard isManaged(folder, inside: folder.deletingLastPathComponent()) else { throw failure("插件目录包含链接。") }
        guard requested.scripts.count <= 32, Set(requested.scripts).count == requested.scripts.count,
              (requested.computerScripts?.count ?? 0) <= 32, Set(requested.computerScripts ?? []).count == (requested.computerScripts?.count ?? 0) else { throw failure("最多选择 32 个不同脚本。") }
        guard !requested.automatic || !requested.scripts.isEmpty else { throw failure("请先选择至少一个启动脚本。") }
        let configURL = folder.appendingPathComponent("FridaGadget.config")
        guard isManaged(configURL, inside: folder) else { throw failure("Gadget 配置包含链接。") }
        let oldConfig = try Data(contentsOf: configURL)
        guard var config = try JSONSerialization.jsonObject(with: oldConfig) as? [String: Any] else { throw failure("Gadget 配置无效。") }
        let priorPath = (config["interaction"] as? [String: Any])?["path"] as? String
        let manifest = folder.appendingPathComponent(manifestName)
        let oldManifest = try? Data(contentsOf: manifest)
        var selection = requested
        if let listen = config["interaction"] as? [String: Any], listen["type"] as? String == "listen" {
            guard let token = listen["token"] as? String, let port = listen["port"] as? Int,
                  (1...65535).contains(port) else { throw failure("原电脑连接配置缺少端口或口令。") }
            selection.listen = ["token": token, "port": String(port), "on_load": listen["on_load"] as? String ?? "resume"]
        }
        var generated: URL?
        if selection.automatic {
            let catalog = Dictionary(uniqueKeysWithValues: try list().map { ($0.id, $0) })
            let scriptsRoot = folder.appendingPathComponent("iOSVMScripts", isDirectory: true)
            guard isManaged(scriptsRoot, inside: folder) else { throw failure("启动脚本目录包含链接。") }
            let generation = UUID().uuidString
            let target = scriptsRoot.appendingPathComponent(generation, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            generated = target
            do {
                selection.fingerprints = [:]
                selection.phoneScriptNames = [:]
                selection.phoneExpressions = nil
                var total = 0
                for (index, id) in selection.scripts.enumerated() {
                    guard let script = catalog[id] else { throw failure("所选脚本已从库中删除，请重新选择。") }
                    let original = try source(script)
                    let prepared = try LCFridaScriptCompatibility.prepare(original, mode: script.effectiveBridgeMode)
                    let data = Data(try LCFridaScriptCompatibility.phoneSource(
                        prepared, id: id, name: script.name, count: selection.scripts.count).utf8)
                    selection.phoneScriptNames?[id.uuidString] = script.name
                    total += data.count
                    guard total <= 32 * 1024 * 1024 else { throw failure("此 App 的启动脚本总计不得超过 32 MiB。") }
                    selection.fingerprints[id.uuidString] = try fingerprint(script, source: original)
                    // Each script remains an independent context. Compiled bundles are never concatenated.
                    let label = String(script.name.prefix(40)).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: ".", with: "_")
                    let file = target.appendingPathComponent(String(format: "%02d-", index) + label + "-" + id.uuidString + ".js")
                    try data.write(to: file, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
                config["interaction"] = ["type": "script-directory", "path": "iOSVMScripts/" + generation, "on_change": "ignore"]
            } catch { LCManagedDirectory.cleanup(target); throw error }
        } else {
            guard let token = selection.listen["token"], let rawPort = selection.listen["port"], let port = Int(rawPort) else {
                throw failure("没有可恢复的电脑连接配置，请重新准备 Gadget。")
            }
            config["interaction"] = ["type": "listen", "address": "127.0.0.1", "token": token, "port": port,
                                     "on_load": selection.listen["on_load"] ?? "resume"]
        }
        config["code_signing"] = selection.allowGenericHooks == true ? "optional" : "required"
        selection.revision = UUID().uuidString
        do {
            try JSONEncoder().encode(selection).write(to: manifest, options: .atomic)
            try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: configURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch {
            try? oldConfig.write(to: configURL, options: .atomic)
            if let oldManifest { try? oldManifest.write(to: manifest, options: .atomic) }
            else { try? fm.removeItem(at: manifest) }
            if let generated { LCManagedDirectory.cleanup(generated) }
            throw error
        }
        // Only disposable generated snapshots; originals stay in the script library.
        if let priorPath {
            let parts = priorPath.split(separator: "/")
            if parts.count == 2, parts[0] == "iOSVMScripts", UUID(uuidString: String(parts[1])) != nil {
                let previous = folder.appendingPathComponent(priorPath)
                if previous.standardizedFileURL.path != generated?.standardizedFileURL.path { LCManagedDirectory.cleanup(previous) }
            }
        }
    }
    static func fingerprint(_ script: Script, source: String) throws -> String {
        // Invalidate old snapshots when source, policy, bridge or preparation logic changes.
        var data = Data("script-compat-v4-phone-command\0\(script.effectiveBridgeMode.rawValue)\0\(script.name)\0".utf8)
        data.append(Data(source.utf8))
        if script.effectiveBridgeMode != .unchanged {
            data.append(Data(try LCFridaScriptCompatibility.resource("objc.js").utf8))
        }
        data.append(Data(try LCFridaScriptCompatibility.resource("phone-logger.js").utf8))
        data.append(Data(try LCFridaScriptCompatibility.resource("analyze.js").utf8))
        return digest(data)
    }
    static func refreshBeforeLaunch(folder: URL, owner: String? = nil) throws {
        let selection = try selection(folder: folder)
        guard selection.automatic else { return }
        if let owner, selection.owner != owner { throw failure("启动脚本配置不属于此 App。请在 Frida 调试中更新专属配置后重试。") }
        let catalog = Dictionary(uniqueKeysWithValues: try list().map { ($0.id, $0) })
        var current: [String: String] = [:]
        for id in selection.scripts {
            guard let script = catalog[id] else { throw failure("启动脚本已被删除，请进入 Frida 调试重新选择脚本。") }
            current[id.uuidString] = try fingerprint(script, source: source(script))
        }
        if current != selection.fingerprints { try apply(selection, folder: folder) }
    }
}
