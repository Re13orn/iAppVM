import Foundation

struct LCNetworkSettings: Codable, Equatable {
    var version = 1
    var capture = false
    var bodies = false
    var proxyType = "off"
    var host = ""
    var port = 8080
    var tlsBypass = false
    var tlsIdentities = false
    enum CodingKeys: String, CodingKey { case version, capture, bodies, proxyType, host, port, tlsBypass, tlsIdentities }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        capture = try values.decode(Bool.self, forKey: .capture)
        bodies = try values.decode(Bool.self, forKey: .bodies)
        proxyType = try values.decode(String.self, forKey: .proxyType)
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 8080
        tlsBypass = try values.decodeIfPresent(Bool.self, forKey: .tlsBypass) ?? false
        tlsIdentities = try values.decodeIfPresent(Bool.self, forKey: .tlsIdentities) ?? false
    }
    func validate() throws {
        guard version == 1, ["off", "http", "socks5"].contains(proxyType), (1...65535).contains(port),
              proxyType == "off" || (!host.isEmpty && host == host.trimmingCharacters(in: .whitespacesAndNewlines) && !host.contains("://") && !host.contains("/") && host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil) else {
            throw LCFridaScriptStore.failure("代理配置无效，请检查类型、服务器和端口。")
        }
    }
}

enum LCTestPresetStore {
    struct Preset: Codable, Identifiable, Equatable {
        var version = 1
        var id = UUID()
        var owner: String
        var name: String
        var modifiedAt = Date()
        var container: String?
        var gadgetID: String?
        var gadgetVersion: String?
        var automatic = false
        var scripts: [UUID] = []
        var captureConsole = true
        var network = LCNetworkSettings()
    }
    static var root: URL { LCPath.docPath.appendingPathComponent("iOSVM/TestPresets") }
    static func requireIdleSigningRequest(_ data: Data?, owner: String? = nil) throws {
        guard let data else { return }
        guard let request = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let state = request["state"] as? String,
              owner == nil || request["guest"] as? String == owner else { throw LCFridaScriptStore.failure("签名任务记录无效，请先在自检中处理签名。") }
        guard ["ready","error","device-error"].contains(state) else { throw LCFridaScriptStore.failure("当前签名任务尚未结束，请先完成签名，再保存或应用预设。") }
    }
    static func directory(_ owner: String) -> URL { root.appendingPathComponent(LCFridaScriptStore.digest(Data(owner.utf8))) }
    static func list(owner: String) throws -> [Preset] {
        let directory = directory(owner)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard LCFridaScriptStore.isManaged(directory, inside: LCPath.docPath) else { throw LCFridaScriptStore.failure("预设目录包含链接。") }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { UUID(uuidString:$0.deletingPathExtension().lastPathComponent) != nil && $0.pathExtension == "json" }.map {
            guard LCFridaScriptStore.isManaged($0, inside: directory) else { throw LCFridaScriptStore.failure("预设文件包含链接。") }
            let value = try JSONDecoder().decode(Preset.self, from: Data(contentsOf:$0))
            guard value.owner == owner, value.id.uuidString == $0.deletingPathExtension().lastPathComponent else { throw LCFridaScriptStore.failure("预设归属无效。") }
            return value
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    static func validate(_ preset: Preset, owner: String, containers: Set<String>, scripts: Set<UUID>, gadgets: Set<String>) throws {
        guard preset.version == 1, preset.owner == owner, !preset.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, preset.name.utf8.count <= 160, !preset.name.contains("\0"),
              preset.scripts.count <= 32, Set(preset.scripts).count == preset.scripts.count else { throw LCFridaScriptStore.failure("预设内容或 App 归属无效。") }
        if let container = preset.container, (!containers.contains(container) || container != URL(fileURLWithPath:container).lastPathComponent || container == "." || container == "..") { throw LCFridaScriptStore.failure("预设中的数据容器已不存在，请重新保存预设。") }
        guard preset.scripts.allSatisfy(scripts.contains) else { throw LCFridaScriptStore.failure("预设引用的脚本已删除，请重新保存脚本组合。") }
        if let gadget = preset.gadgetID, !gadgets.contains(gadget) { throw LCFridaScriptStore.failure("预设引用的 Gadget 版本已不存在，请重新下载或导入。") }
        guard !preset.automatic || (preset.gadgetID != nil && !preset.scripts.isEmpty) else { throw LCFridaScriptStore.failure("自动运行需要 Gadget 和至少一个脚本。") }
        try preset.network.validate()
    }
    static func save(_ preset: Preset) throws {
        let directory = directory(preset.owner)
        try LCManagedDirectory.ensureWritable(directory, inside: LCPath.docPath)
        guard !preset.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, preset.name.utf8.count <= 160, !preset.name.contains("\0") else { throw LCFridaScriptStore.failure("预设名称不能为空或超过 160 字节。") }
        let file = directory.appendingPathComponent(preset.id.uuidString + ".json")
        guard LCFridaScriptStore.isManaged(file, inside:directory) else { throw LCFridaScriptStore.failure("预设路径包含链接。") }
        try JSONEncoder().encode(preset).write(to:file, options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:file.path)
    }
    static func remove(_ preset: Preset) throws {
        let directory = directory(preset.owner), file = directory.appendingPathComponent(preset.id.uuidString + ".json")
        guard LCFridaScriptStore.isManaged(file, inside:LCPath.docPath) else { throw LCFridaScriptStore.failure("预设路径包含链接。") }
        try FileManager.default.removeItem(at:file)
    }
}

/// A bounded, recoverable transaction for settings files only. Never snapshots or deletes guest data.
enum LCSettingsTransaction {
    struct Change: Codable { var path: String; var before: Data?; var after: Data }
    struct Journal: Codable { var version = 1; var owner: String; var changes: [Change] }
    static func url(owner: String) -> URL { LCTestPresetStore.directory(owner).appendingPathComponent("pending-apply.json") }
    static func allowed(_ path: String, owner: String) -> Bool {
        guard owner == URL(fileURLWithPath:owner).lastPathComponent, owner.hasSuffix(".app"), !owner.contains("\0") else { return false }
        return path == "Applications/" + owner + "/LCAppInfo.plist" || path == "iOSVM/NetworkSettingsV2/" + owner + ".json"
    }
    static func checked(_ path: String, root: URL) throws -> URL {
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard LCFridaScriptStore.isManaged(file, inside:root) else { throw LCFridaScriptStore.failure("配置事务包含越界或链接路径。") }
        return file
    }
    static func recover(owner: String, root: URL = LCPath.docPath, journalURL: URL? = nil) throws {
        let file = journalURL ?? url(owner:owner)
        guard LCFridaScriptStore.isManaged(file, inside:root) else { throw LCFridaScriptStore.failure("恢复记录路径无效。") }
        guard FileManager.default.fileExists(atPath:file.path) else { return }
        let journalData = try Data(contentsOf:file)
        guard journalData.count <= 4*1024*1024 else { throw LCFridaScriptStore.failure("恢复记录过大。") }
        let journal = try JSONDecoder().decode(Journal.self, from:journalData)
        guard journal.version == 1, journal.owner == owner, journal.changes.count <= 4, Set(journal.changes.map(\.path)).count == journal.changes.count else { throw LCFridaScriptStore.failure("恢复记录归属或格式无效。") }
        // Validate all current files before restoring any; never overwrite an unrelated subsequent edit.
        for change in journal.changes {
            guard allowed(change.path,owner:owner) else { throw LCFridaScriptStore.failure("恢复记录不属于此 App 的配置范围。") }
            let path = try checked(change.path,root:root)
            let current = try FileManager.default.fileExists(atPath:path.path) ? Data(contentsOf:path) : nil
            guard current == change.before || current == change.after else { throw LCFridaScriptStore.failure("配置已被其他操作修改，自动恢复已停止，请保留现场检查。") }
        }
        for change in journal.changes.reversed() {
            let path = try checked(change.path,root:root)
            let current = try FileManager.default.fileExists(atPath:path.path) ? Data(contentsOf:path) : nil
            if current == change.before { continue }
            if let previous = change.before { try previous.write(to:path,options:.atomic) }
            else if FileManager.default.fileExists(atPath:path.path) { try FileManager.default.removeItem(at:path) }
        }
        try FileManager.default.removeItem(at:file)
    }
    static func apply(owner: String, changes: [Change], root: URL = LCPath.docPath, journalURL: URL? = nil) throws {
        let file = journalURL ?? url(owner:owner)
        guard !changes.isEmpty, changes.count <= 4, Set(changes.map(\.path)).count == changes.count, !FileManager.default.fileExists(atPath:file.path), LCFridaScriptStore.isManaged(file,inside:root) else { throw LCFridaScriptStore.failure("存在未完成配置切换，请先恢复。") }
        for change in changes {
            guard allowed(change.path,owner:owner), change.after.count <= 1024*1024, (change.before?.count ?? 0) <= 1024*1024 else { throw LCFridaScriptStore.failure("事务内容超出此 App 的配置范围。") }
            let path = try checked(change.path,root:root)
            let current = try FileManager.default.fileExists(atPath:path.path) ? Data(contentsOf:path) : nil
            guard current == change.before else { throw LCFridaScriptStore.failure("配置在准备期间发生变化，请刷新后重试。") }
        }
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(Journal(owner:owner,changes:changes)).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        do {
            for change in changes {
                let path = try checked(change.path,root:root)
                try change.after.write(to:path,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
                guard try Data(contentsOf:path) == change.after else { throw LCFridaScriptStore.failure("配置保存校验失败。") }
            }
            try FileManager.default.removeItem(at:file)
        } catch {
            do { try recover(owner:owner,root:root,journalURL:file) }
            catch { throw LCFridaScriptStore.failure("配置应用中断且未能恢复，请到启动诊断恢复上次配置。") }
            throw error
        }
    }
}
