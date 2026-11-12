#if IOSVM_TESTING
import Foundation

enum LCSandboxBackupAcceptance {
    @MainActor static func run(_ model: LCAppModel) async {
        guard model.appInfo.relativeBundlePath == "dev.iosvm.debugcheck.app" else { return }
        let fm = FileManager.default
        let reportURL = LCPath.docPath.appendingPathComponent("iOSVMUITests/backup-acceptance.json")
        var report: [String: Any] = ["state": "running"]
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw LCSandboxBackupStore.fail(message) } }
        do {
            let container = LCContainer(folderName: UUID().uuidString, name: "文件测试沙盒", isShared: false)
            container.makeLCContainerInfoPlist(appIdentifier: model.bundleIdentifier, keychainGroupId: 1)
            model.uiContainers.append(container); model.appInfo.containers = model.uiContainers
            model.uiSelectedContainer = container; model.uiDefaultDataFolder = container.folderName
            model.appInfo.dataUUID = container.folderName; model.appInfo.save()
            let context = try LCSandboxBackupManager.context(model, container)
            func put(_ path: String, _ text: String) throws {
                let file = context.root.appendingPathComponent(path)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
            }
            try put("Documents/change.txt", "before")
            try put("Documents/deleted.txt", "restore")
            try put("Library/Preferences/fixture.txt", "fixture")
            try put("Library/iOSVM/Sessions/fixture.log", "keep current log")
            let baseline = try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.create($0, name: "测试前基线") }
            var lease: LCSandboxBackupStore.Lease? = try LCSandboxBackupStore.reserve(context.root)
            var launchBlocked = false
            do { try await model.runApp() } catch { launchBlocked = true }
            withExtendedLifetime(lease) {}; lease = nil
            await Task.yield()
            try require(launchBlocked, "Launch was not blocked by maintenance lease")
            let launch = try IOSVMProcessRegistry.shared.beginBundle(model.appInfo.relativeBundlePath, container: container.folderName)
            var runningBlocked = false
            do { _ = try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.create($0, name: "must refuse") } }
            catch { runningBlocked = true }
            _ = IOSVMProcessRegistry.shared.finishLaunch(launch, state: "failed", reason: "Own backup acceptance fixture finished")
            try require(runningBlocked, "Active container was not blocked")
            try put("Documents/change.txt", "after!")
            try fm.removeItem(at: context.root.appendingPathComponent("Documents/deleted.txt"))
            try put("Documents/added.txt", "added")
            let diff = try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.compare(baseline.id, $0) }
            try require(diff.added == 1 && diff.modified == 1 && diff.deleted == 1, "Diff counts mismatch")
            let rescue = try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.restore(baseline.id, $0, expected: diff) }
            let restored = try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.compare(baseline.id, $0) }
            try require(restored.changes.isEmpty && rescue.reason == "before-restore", "Atomic restore did not match backup")
            try put("Documents/change.txt", "crash simulation")
            let beforeCrash = try LCSandboxBackupStore.compare(baseline.id, context)
            do { _ = try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.restore(baseline.id, $0, expected: beforeCrash, testStopAfterSwap: true) } }
            catch { /* expected interrupted transaction */ }
            try require(LCSandboxBackupStore.pending(context), "Crash journal missing")
            try require(LCLaunchPreflight.check(model).contains { $0.id == "sandbox-restore" && $0.blocking }, "Preflight did not block pending restore")
            var pendingBlocked = false
            do { try await model.runApp() } catch { pendingBlocked = true }
            await Task.yield()
            try require(pendingBlocked, "Pending restore did not block launch")
            try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.recover($0) }
            try require(!LCSandboxBackupStore.pending(context), "Recovery did not clear journal")
            try put("Documents/change.txt", "after!")
            try fm.removeItem(at: context.root.appendingPathComponent("Documents/deleted.txt"))
            try put("Documents/added.txt", "added")
            report = ["state": "passed", "container": container.folderName, "backup": baseline.id,
                      "backupHome": context.home.path.replacingOccurrences(of: LCPath.docPath.resolvingSymlinksInPath().path, with: ""),
                      "checks": ["private-fixture-only", "backup", "added-modified-deleted", "atomic-restore", "rescue-backup", "launch-lease", "active-process-blocked", "interrupted-restore", "pending-launch-blocked", "recovery"]]
        } catch { report["state"] = "failed"; report["error"] = error.localizedDescription }
        try? fm.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
    }
}
#endif
