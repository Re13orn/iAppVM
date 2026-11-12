import Foundation
import CryptoKit

struct LCFridaKeychainIndex {
    let items: [LCGuestKeychainItem]
    let warnings: [String]
    let accessGroup: String
}

enum LCFridaKeychainInspector {
    static let scriptName = "iAppVM Keychain Inspector"
    static let scriptID = UUID(uuidString: "A11C0DE0-1A55-4C11-9E33-1A9C42E77A11")!
    static let indexName = "keychain-index.json"
    static let authenticatedIndexName = "keychain-index-auth.json"

    static func installScript() throws -> LCFridaScriptStore.Script {
        let source = try LCFridaScriptCompatibility.resource("keychain-inspector.js")
        return try LCFridaScriptStore.save(
            id: scriptID,
            name: scriptName,
            source: source,
            bridgeMode: .automatic
        )
    }

    @MainActor
    static func enableForNextLaunch(model: LCAppModel) throws {
        guard !model.isAppRunning else {
            throw "请先关闭此 App 的所有测试窗口。"
        }
        guard let folder = LCFridaSetup.folder(for: model.appInfo),
              LCFridaSetup.enabled(model.appInfo) else {
            throw "请先在 Frida 调试页启用 Gadget。"
        }
        _ = try installScript()
        var selection = try LCFridaScriptStore.selection(folder: folder)
        guard selection.owner == model.appInfo.relativeBundlePath else {
            throw "当前调试目录不属于此 App。请回到 Frida 调试页更新配置。"
        }
        if !selection.scripts.contains(scriptID) {
            selection.scripts.append(scriptID)
        }
        selection.automatic = true
        try LCFridaScriptStore.apply(selection, folder: folder)
        model.uiIsJITNeeded = selection.allowGenericHooks == true
        model.appInfo.save()
    }

    static func latestIndex(model: LCAppModel, container: LCContainer) throws -> LCFridaKeychainIndex? {
        let root = container.containerURL
        let records = IOSVMProcessRegistry.shared.records(forBundle: model.appInfo.relativeBundlePath)
            .compactMap { $0 as? [String: Any] }
            .filter {
                $0["container"] as? String == container.folderName
                    && $0["state"] as? String == "running"
            }
        guard let record = records.max(by: {
            ($0["startedAt"] as? Double ?? 0) < ($1["startedAt"] as? Double ?? 0)
        }), let pid = record["pid"] as? Int else { return nil }
        let startedAt = record["startedAt"] as? Double ?? 0
        guard let session = LCDebugSession.list(root: root).first(where: {
            $0.pid == pid && ($0.value["startedAt"] as? Double ?? 0) >= startedAt - 1
        }) else { return nil }
        let directory = session.folder.appendingPathComponent("phone-scripts", isDirectory: true)
        let files = [authenticatedIndexName, indexName]
            .map(directory.appendingPathComponent)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let file = files.max(by: {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }),
              let data = try? LCFridaLogBoundary.readData(file, inside: root, maximumBytes: 4 * 1024 * 1024),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let accessGroup = value["accessGroup"] as? String,
              accessGroup == (try LCGuestKeychainBrowser.accessGroup(for: container)) else {
            return nil
        }
        let rawItems = value["items"] as? [[String: Any]] ?? []
        let warnings = (value["warnings"] as? [[String: Any]] ?? []).map {
            ($0["type"] as? String ?? "Keychain") + "：" +
                ($0["message"] as? String ?? "未知读取错误")
        }
        let items = rawItems.compactMap { raw -> LCGuestKeychainItem? in
            guard let type = raw["_type"] as? String else { return nil }
            let itemClass: LCGuestKeychainClass
            switch type {
            case "通用密码": itemClass = .genericPassword
            case "互联网密码": itemClass = .internetPassword
            case "证书": itemClass = .certificate
            case "密钥": itemClass = .key
            case "身份": itemClass = .identity
            default: return nil
            }
            var attributes = raw
            attributes.removeValue(forKey: "_type")
            attributes.removeValue(forKey: "_class")
            let server = attributes["srvr"] as? String ?? ""
            let port = attributes["port"].map { String(describing: $0) } ?? ""
            let path = attributes["path"] as? String ?? ""
            let service = attributes["svce"] as? String
                ?? ([server, port].filter { !$0.isEmpty }.joined(separator: ":")) + path
            let account = attributes["acct"] as? String ?? ""
            let label = attributes["labl"] as? String ?? ""
            let created = date(attributes["cdat"])
            let modified = date(attributes["mdat"])
            let reference = (attributes["_persistentRefBase64"] as? String).flatMap {
                Data(base64Encoded: $0)
            }
            let seed = [type, service, account, label, String(created?.timeIntervalSince1970 ?? 0)].joined(separator: "\u{1f}")
            let digest = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
            return LCGuestKeychainItem(
                id: "frida-" + digest,
                itemClass: itemClass,
                source: .frida,
                service: service.isEmpty ? itemClass.rawValue : service,
                account: account,
                label: label,
                createdAt: created,
                modifiedAt: modified,
                persistentReference: reference,
                attributes: attributes
            )
        }
        return LCFridaKeychainIndex(items: items, warnings: warnings, accessGroup: accessGroup)
    }

    private static func date(_ value: Any?) -> Date? {
        if let value = value as? [String: Any], let unix = value["unix"] as? Double {
            return Date(timeIntervalSince1970: unix)
        }
        return nil
    }
}
