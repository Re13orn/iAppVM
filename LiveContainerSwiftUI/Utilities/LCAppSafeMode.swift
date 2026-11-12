import CryptoKit
import Foundation

enum LCAppSafeMode {
    private struct Backup: Codable {
        let version: Int
        let owner: String
        let createdAt: Date
        let appInfo: Data
        let network: Data?
    }

    static var root: URL { LCPath.docPath.appendingPathComponent("iOSVM/SafeMode", isDirectory: true) }

    static func isActive(_ model: LCAppModel) -> Bool {
        FileManager.default.fileExists(atPath: url(owner: model.appInfo.relativeBundlePath).path)
    }

    @MainActor
    static func activate(_ model: LCAppModel) throws {
        guard !model.isAppRunning else { throw "请先关闭此 App 的所有测试窗口。" }
        let owner = model.appInfo.relativeBundlePath!
        let url = url(owner: owner)
        if !FileManager.default.fileExists(atPath: url.path) {
            try LCManagedDirectory.ensureWritableChain(root, inside: LCPath.docPath)
            let appInfoURL = URL(fileURLWithPath: model.appInfo.bundlePath()).appendingPathComponent("LCAppInfo.plist")
            let appInfo = try LCFridaLogBoundary.readData(appInfoURL, inside: URL(fileURLWithPath: model.appInfo.bundlePath()), maximumBytes: 4 * 1024 * 1024)
            let networkURL = LCTestPresetManager.networkURL(model)
            let network = try? LCFridaLogBoundary.readData(networkURL, inside: LCPath.docPath, maximumBytes: 16384)
            let backup = Backup(version: 1, owner: owner, createdAt: Date(), appInfo: appInfo, network: network)
            try JSONEncoder().encode(backup).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        let appInfoURL = URL(fileURLWithPath: model.appInfo.bundlePath()).appendingPathComponent("LCAppInfo.plist")
        guard var info = NSDictionary(contentsOf: appInfoURL) as? [String: Any] else {
            throw "无法读取应用元数据。"
        }
        info["dontInjectTweakLoader"] = true
        info["dontLoadTweakLoader"] = true
        info["isJITNeeded"] = false
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: appInfoURL, options: .atomic)

        let networkURL = LCTestPresetManager.networkURL(model)
        let disabled = LCNetworkSettings()
        try LCManagedDirectory.ensureWritable(networkURL.deletingLastPathComponent(), inside: LCPath.docPath)
        try JSONEncoder().encode(disabled).write(to: networkURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: networkURL.path)

        model.appInfo.info().setDictionary(info)
        model.uiDontInjectTweakLoader = true
        model.uiDontLoadTweakLoader = true
        model.uiIsJITNeeded = false
        model.appInfo.save()
    }

    @MainActor
    static func restore(_ model: LCAppModel) throws {
        guard !model.isAppRunning else { throw "请先关闭此 App 的所有测试窗口。" }
        let owner = model.appInfo.relativeBundlePath!
        let file = url(owner: owner)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw "此 App 没有可恢复的安全模式快照。"
        }
        let backup = try JSONDecoder().decode(
            Backup.self,
            from: LCFridaLogBoundary.readData(file, inside: LCPath.docPath, maximumBytes: 8 * 1024 * 1024)
        )
        guard backup.version == 1, backup.owner == owner else {
            throw "安全模式快照与当前 App 不匹配。"
        }
        let appInfoURL = URL(fileURLWithPath: model.appInfo.bundlePath()).appendingPathComponent("LCAppInfo.plist")
        try backup.appInfo.write(to: appInfoURL, options: .atomic)
        let networkURL = LCTestPresetManager.networkURL(model)
        if let network = backup.network {
            try LCManagedDirectory.ensureWritable(networkURL.deletingLastPathComponent(), inside: LCPath.docPath)
            try network.write(to: networkURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: networkURL.path)
        } else if FileManager.default.fileExists(atPath: networkURL.path) {
            try FileManager.default.removeItem(at: networkURL)
        }
        try FileManager.default.removeItem(at: file)
        LCTestPresetManager.reload(model)
    }

    private static func url(owner: String?) -> URL {
        let digest = SHA256.hash(data: Data((owner ?? "unknown").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest + ".json")
    }
}
