#if IOSVM_TESTING
import Foundation

/// Device acceptance for host-owned configuration only. Never launches a guest or reads its wallet data.
enum LCStorageAcceptance {
    @MainActor static func run(app: LCAppModel?, repairFrida: Bool) async {
        let fm = FileManager.default
        let legacy = LCPath.docPath.appendingPathComponent("iOSVM/NetworkSettings")
        let directory = IOSVMGuestAccess.networkSettingsDirectory(documents: LCPath.docPath)
        var report: [String: Any] = [:]
        do {
            let originals = try Dictionary(uniqueKeysWithValues: fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
            report["migrationPerformed"] = try LCManagedDirectory.migrateLegacy(legacy, to: directory, inside: LCPath.docPath)
            report["legacyDirectoryRetained"] = fm.fileExists(atPath: legacy.path)
            let preserved = try originals.allSatisfy { name, bytes in try Data(contentsOf: directory.appendingPathComponent(name)) == bytes }
            guard preserved else { throw failure("Existing settings changed") }
            report["existingConfigurationsPreserved"] = true
            report["ownerAfter"] = try fm.attributesOfItem(atPath: directory.path)[.ownerAccountID]
            let probe = directory.appendingPathComponent(".iosvm-acceptance-" + UUID().uuidString + ".json")
            defer { try? fm.removeItem(at: probe) }
            for type in ["http", "socks5"] {
                let value: [String: Any] = ["version": 1, "capture": true, "bodies": false, "proxyType": type, "host": "127.0.0.1", "port": 8080]
                let bytes = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
                try bytes.write(to: probe, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: probe.path)
                guard try Data(contentsOf: probe) == bytes else { throw failure("Saved configuration differs") }
            }
            report["atomicSaveAndReplace"] = true
            report["secondEnsureDidNotMigrate"] = try LCManagedDirectory.migrateLegacy(legacy, to: directory, inside: LCPath.docPath) == false
        } catch { report["networkError"] = String(describing: error) }
        if repairFrida {
            do {
                guard let app, !app.isAppRunning else { throw failure("App missing or still active") }
                let managed = LCPath.tweakPath.appendingPathComponent("iOSVM-Frida-" + app.appInfo.relativeBundlePath)
                let before = try Data(contentsOf: managed.appendingPathComponent(LCFridaSetup.configuration))
                try await LCFridaSetup.prepare(app.appInfo)
                app.uiTweakFolder = app.appInfo.tweakFolder
                try await LCFridaSetup.prepare(app.appInfo)
                let after = try Data(contentsOf: LCFridaSetup.folder(for: app.appInfo)!.appendingPathComponent(LCFridaSetup.configuration))
                report["fridaConnectionIdentityPreserved"] = before == after
                guard before == after else { throw failure("Existing Gadget configuration changed") }
                try await IOSVMDeviceSigning.sign(app.appInfo)
                let saved = NSDictionary(contentsOfFile: app.appInfo.bundlePath() + "/LCAppInfo.plist")
                report["fridaEnabled"] = LCFridaSetup.enabled(app.appInfo)
                report["selectedFolderPersisted"] = saved?["LCTweakFolder"] as? String == app.appInfo.tweakFolder
                report["deviceSigned"] = saved?["IOSVMDeviceSigned"] as? Bool ?? false
                report["port"] = (try LCFridaSetup.config(app.appInfo)["interaction"] as? [String: Any])?["port"]
            } catch { report["fridaError"] = String(describing: error) }
        }
        let output = LCPath.docPath.appendingPathComponent("iOSVMUITests")
        try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("storage-acceptance.json"), options: .atomic)
    }
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "IOSVMStorageAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
#endif
