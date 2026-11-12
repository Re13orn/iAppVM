#if IOSVM_TESTING
import Foundation
import Security

enum LCGuestKeychainAcceptance {
    private static let service = "dev.iappvm.keychain.acceptance"
    private static let account = "auditor"
    private static let folderName = "Keychain-Acceptance-Container"

    @MainActor
    static func run(_ app: LCAppModel, action: String) async -> [String: Any] {
        var report: [String: Any] = ["state": "running", "action": action]
        do {
            let container = app.uiContainers.first { $0.folderName == folderName }
                ?? makeContainer(app)
            if !app.uiContainers.contains(where: { $0.folderName == container.folderName }) {
                app.uiContainers.append(container)
            }
            app.uiSelectedContainer = container
            let accessGroup = try LCGuestKeychainBrowser.accessGroup(for: container)
            report["accessGroup"] = accessGroup
            report["container"] = container.folderName

            switch action {
            case "cleanup":
                removeFixture(accessGroup: accessGroup, container: container)
                report["state"] = "cleaned"
            default:
                removeFixture(accessGroup: accessGroup, container: container)
                try addFixture(accessGroup: accessGroup, container: container)
                let snapshot = try LCGuestKeychainBrowser.snapshot(for: container)
                guard let item = snapshot.items.first(where: {
                    $0.itemClass == .genericPassword && $0.service == service && $0.account == account
                }) else {
                    throw "合成 Keychain 条目未出现在当前容器的查询结果中。"
                }
                let value = try LCGuestKeychainBrowser.reveal(item, in: container)
                guard value.displayText == "iappvm-keychain-fixture" else {
                    throw "Keychain 值回读不一致。"
                }
                let metadata = LCGuestKeychainBrowser.metadataDictionary(item)
                guard metadata["service"] as? String == service,
                      metadata["value"] == nil else {
                    throw "Keychain 元数据导出包含意外内容。"
                }
                report["state"] = "passed"
                report["itemCount"] = snapshot.items.count
                report["warnings"] = snapshot.warnings
                report["metadataFields"] = Array(metadata.keys).sorted()
            }
        } catch {
            report["state"] = "failed"
            report["error"] = error.localizedDescription
        }

        let output = LCPath.docPath.appendingPathComponent("iOSVMUITests")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("guest-keychain.json"), options: .atomic)
        return report
    }

    @MainActor
    static func diagnose(_ apps: [LCAppModel]) -> [String: Any] {
        var appReports: [[String: Any]] = []
        for app in apps {
            var containers: [[String: Any]] = []
            for container in app.uiContainers {
                do {
                    let snapshot = try LCGuestKeychainBrowser.snapshot(for: container)
                    let counts = Dictionary(grouping: snapshot.items, by: \.itemClass)
                        .mapValues(\.count)
                    containers.append([
                        "container": container.folderName,
                        "group": snapshot.keychainGroupID,
                        "accessGroup": snapshot.accessGroup,
                        "counts": Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }),
                        "warnings": snapshot.warnings
                    ])
                } catch {
                    containers.append([
                        "container": container.folderName,
                        "error": error.localizedDescription
                    ])
                }
            }
            appReports.append([
                "app": app.displayName,
                "bundle": app.bundleIdentifier,
                "containers": containers
            ])
        }
        let report: [String: Any] = [
            "version": 1,
            "apps": appReports
        ]
        let output = LCPath.docPath.appendingPathComponent("iOSVMUITests")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("keychain-diagnose.json"), options: .atomic)
        return report
    }

    @MainActor
    private static func makeContainer(_ app: LCAppModel) -> LCContainer {
        let container = LCContainer(folderName: folderName, name: "Keychain 验收", isShared: false)
        container.makeLCContainerInfoPlist(
            appIdentifier: app.bundleIdentifier,
            keychainGroupId: 1
        )
        return container
    }

    private static func addFixture(accessGroup: String, container: LCContainer) throws {
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "iAppVM Keychain Fixture",
            kSecValueData as String: Data("iappvm-keychain-fixture".utf8),
            "alis": container.folderName,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw "写入合成 Keychain 条目失败（OSStatus \(status)）。"
        }
    }

    private static func removeFixture(accessGroup: String, container: LCContainer) {
        _ = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            "alis": container.folderName
        ] as CFDictionary)
    }
}
#endif
