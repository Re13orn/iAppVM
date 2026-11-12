import Foundation
import Darwin

@main struct SandboxBackupTests {
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("iappvm-backup-tests-" + UUID().uuidString)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: workspace) }
        let root = workspace.appendingPathComponent("Container"), storage = workspace.appendingPathComponent("Backups")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        func put(_ path: String, _ text: String, base: URL? = nil) throws {
            let file = (base ?? root).appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        func text(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw LCSandboxBackupStore.fail(message) } }
        func rejects(_ message: String, _ action: () throws -> Void) throws {
            do { try action() } catch { print("PASS rejection:", message); return }
            throw LCSandboxBackupStore.fail("Unexpected success: " + message)
        }
        try put("Documents/change.txt", "aaaa")
        try put("Documents/remove.txt", "restore me")
        try put("Library/Preferences/settings.plist", "prefs")
        try put("Library/iOSVM/Sessions/log", "managed old")
        try put("LCContainerInfo.plist", "identity old")
        try fm.createDirectory(at: root.appendingPathComponent("Documents/Empty"), withIntermediateDirectories: true)
        let outside = workspace.appendingPathComponent("Outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("outside secret unchanged".utf8).write(to: outside.appendingPathComponent("secret"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("External"), withDestinationURL: outside)
        let ctx = try LCSandboxBackupStore.Context(owner: "fixture.app", container: "fixture", root: root, storage: storage)
        let backup = try LCSandboxBackupStore.create(ctx, name: "Before test")
        try check(backup.files == 3, "Only ordinary included files")
        try check(backup.skipped.contains("External") && backup.skipped.contains("Library/iOSVM"), "Exclusions listed")
        try check(!fm.fileExists(atPath: ctx.home.appendingPathComponent(backup.id + "/files/External/secret").path), "External data not copied")
        let oldDate = try fm.attributesOfItem(atPath: root.appendingPathComponent("Documents/change.txt").path)[.modificationDate] as! Date
        try put("Documents/change.txt", "bbbb") // same bytes, same timestamp: hash must detect it
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: root.appendingPathComponent("Documents/change.txt").path)
        try fm.removeItem(at: root.appendingPathComponent("Documents/remove.txt"))
        try put("Documents/added.txt", "new")
        try put("LCContainerInfo.plist", "identity current")
        try put("Library/iOSVM/Sessions/log", "managed current")
        let diff = try LCSandboxBackupStore.compare(backup.id, ctx)
        try check(diff.added == 1 && diff.modified == 1 && diff.deleted == 1, "Accurate added/modified/deleted")
        let rescue = try LCSandboxBackupStore.restore(backup.id, ctx, expected: diff)
        try check(try text("Documents/change.txt") == "aaaa" && text("Documents/remove.txt") == "restore me", "Files restored")
        try check(!fm.fileExists(atPath: root.appendingPathComponent("Documents/added.txt").path), "Added file removed")
        try check(try text("LCContainerInfo.plist") == "identity current" && text("Library/iOSVM/Sessions/log") == "managed current", "Current excluded controls preserved")
        try check(try fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("External").path) == outside.path, "Link preserved verbatim")
        try check(try String(contentsOf: outside.appendingPathComponent("secret"), encoding: .utf8) == "outside secret unchanged", "External target untouched")
        try check(rescue.reason == "before-restore" && LCSandboxBackupStore.list(ctx).count == 2, "Recovery backup retained")
        print("PASS: snapshot/diff/hash/restore/exclusions/safety backup")
        let stale = try LCSandboxBackupStore.compare(backup.id, ctx)
        try put("Documents/new-after-confirm", "later")
        try rejects("stale comparison") { _ = try LCSandboxBackupStore.restore(backup.id, ctx, expected: stale) }
        let latest = try LCSandboxBackupStore.compare(backup.id, ctx)
        try rejects("interruption after atomic swap") { _ = try LCSandboxBackupStore.restore(backup.id, ctx, expected: latest, testStopAfterSwap: true) }
        try check(LCSandboxBackupStore.pending(ctx), "Interrupted transaction retained")
        try rejects("new backup during pending restore") { _ = try LCSandboxBackupStore.create(ctx, name: "unsafe") }
        try LCSandboxBackupStore.recover(ctx); try LCSandboxBackupStore.recover(ctx)
        try check(!LCSandboxBackupStore.pending(ctx), "Recovery idempotent")
        try check(try LCSandboxBackupStore.compare(backup.id, ctx).changes.isEmpty, "Recovery installed complete snapshot")
        try put("Documents/prepared-only", "unchanged until swap")
        let prepared = try LCSandboxBackupStore.compare(backup.id, ctx)
        try rejects("interruption before atomic swap") { _ = try LCSandboxBackupStore.restore(backup.id, ctx, expected: prepared, testStopBeforeSwap: true) }
        try LCSandboxBackupStore.recover(ctx)
        try check(try text("Documents/prepared-only") == "unchanged until swap", "Pre-swap recovery keeps original data")
        _ = try LCSandboxBackupStore.restore(backup.id, ctx, expected: LCSandboxBackupStore.compare(backup.id, ctx))
        // Read-only ordinary directories are restored, then their verified old
        // disposable copies are cleaned without loosening live permissions.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.appendingPathComponent("Documents/Empty").path)
        let readOnlyDiff = try LCSandboxBackupStore.compare(backup.id, ctx)
        _ = try LCSandboxBackupStore.restore(backup.id, ctx, expected: readOnlyDiff)
        try check(!LCSandboxBackupStore.pending(ctx), "Read-only directory cleanup succeeds")
        print("PASS: stale preview and interrupted transaction recovery")
        // File-to-directory changes and metadata-only permission changes.
        try fm.removeItem(at: root.appendingPathComponent("Documents/change.txt"))
        try put("Documents/change.txt/child", "nested")
        let typeDiff = try LCSandboxBackupStore.compare(backup.id, ctx)
        try check(typeDiff.changes.contains { $0.path == "Documents/change.txt" && $0.status == "修改" }, "Type change recorded")
        _ = try LCSandboxBackupStore.restore(backup.id, ctx, expected: typeDiff)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: root.appendingPathComponent("Documents/change.txt").path)
        try check(try LCSandboxBackupStore.compare(backup.id, ctx).modified == 1, "Mode change detected")
        // Tampered payload must fail before any original data is replaced.
        let payload = ctx.home.appendingPathComponent(backup.id + "/files/Documents/change.txt")
        try Data("tampered".utf8).write(to: payload)
        let beforeTamper = try LCSandboxBackupStore.compare(backup.id, ctx)
        try rejects("corrupted backup payload") { _ = try LCSandboxBackupStore.restore(backup.id, ctx, expected: beforeTamper) }
        try check(try text("Documents/change.txt") == "aaaa", "Corruption rejection preserves source")
        try Data("aaaa".utf8).write(to: payload)
        let protectedFile = root.appendingPathComponent("Documents/change.txt")
        if chflags(protectedFile.path, UInt32(UF_IMMUTABLE)) == 0 {
            do {
                let protectedDiff = try LCSandboxBackupStore.compare(backup.id, ctx)
                try rejects("immutable source refused before swap") { _ = try LCSandboxBackupStore.restore(backup.id, ctx, expected: protectedDiff) }
                try check(!LCSandboxBackupStore.pending(ctx), "Protected file rejection leaves no restore transaction")
            } catch { _ = chflags(protectedFile.path, 0); throw error }
            _ = chflags(protectedFile.path, 0)
        }
        // Wrong owner, malformed path, and changed link conflicts all fail closed.
        let index = ctx.home.appendingPathComponent(backup.id + "/manifest.json")
        let originalIndex = try Data(contentsOf: index)
        var tampered = try JSONDecoder().decode(LCSandboxBackupStore.Manifest.self, from: originalIndex)
        tampered.name = "Changed after confirmation"; try JSONEncoder().encode(tampered).write(to: index)
        try rejects("baseline changed after comparison") { _ = try LCSandboxBackupStore.restore(backup.id, ctx, expected: beforeTamper) }
        tampered.name = backup.name
        tampered.owner = "foreign.app"; try JSONEncoder().encode(tampered).write(to: index)
        try rejects("foreign owner") { _ = try LCSandboxBackupStore.load(backup.id, ctx) }
        tampered.owner = ctx.owner; tampered.entries[0].path = "../escape"; try JSONEncoder().encode(tampered).write(to: index)
        try rejects("manifest traversal") { _ = try LCSandboxBackupStore.load(backup.id, ctx) }
        try originalIndex.write(to: index)
        try fm.removeItem(at: root.appendingPathComponent("Documents/change.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Documents/change.txt"), withDestinationURL: outside.appendingPathComponent("secret"))
        let linkDiff = try LCSandboxBackupStore.compare(backup.id, ctx)
        try rejects("snapshot conflicts with current symlink") { _ = try LCSandboxBackupStore.restore(backup.id, ctx, expected: linkDiff) }
        // Operation leases block launch/maintenance for the same canonical root only.
        var lease: LCSandboxBackupStore.Lease? = try LCSandboxBackupStore.reserve(root)
        try rejects("concurrent operation") { _ = try LCSandboxBackupStore.reserve(root) }
        withExtendedLifetime(lease) {}; lease = nil
        let secondLease = try LCSandboxBackupStore.reserve(root); withExtendedLifetime(secondLease) {}
        // Storage symlinks must not create writes in their targets.
        let storageLink = workspace.appendingPathComponent("StorageLink")
        try fm.createSymbolicLink(at: storageLink, withDestinationURL: outside)
        let bad = try LCSandboxBackupStore.Context(owner: "fixture.app", container: "second", root: root, storage: storageLink)
        try rejects("backup storage symlink") { _ = try LCSandboxBackupStore.create(bad, name: "unsafe") }
        try check(try fm.contentsOfDirectory(atPath: outside.path) == ["secret"], "No writes outside storage")
        try LCSandboxBackupStore.delete(backup.id, ctx)
        try check(try text("Documents/change.txt") == "outside secret unchanged", "Deleting backup does not edit current data")
        let blockedDirectory = root.appendingPathComponent("Unreadable")
        try fm.createDirectory(at: blockedDirectory, withIntermediateDirectories: false)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blockedDirectory.path)
        try rejects("unreadable source is not silently skipped") { _ = try LCSandboxBackupStore.create(ctx, name: "partial must not publish") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedDirectory.path)
        let rootLink = workspace.appendingPathComponent("RootLink")
        try fm.createSymbolicLink(at: rootLink, withDestinationURL: root)
        try rejects("container root symlink") { _ = try LCSandboxBackupStore.Context(owner: "fixture.app", container: "linked", root: rootLink, storage: storage) }
        try rejects("backup nested in source") { _ = try LCSandboxBackupStore.Context(owner: "fixture.app", container: "nested", root: root, storage: root.appendingPathComponent("backups")) }
        let sparse = root.appendingPathComponent("too-large")
        fm.createFile(atPath: sparse.path, contents: nil)
        let sparseHandle = try FileHandle(forWritingTo: sparse)
        try sparseHandle.truncate(atOffset: UInt64(LCSandboxBackupStore.maximumBytes + 1)); try sparseHandle.close()
        try rejects("oversized file rejected before reading") { _ = try LCSandboxBackupStore.create(ctx, name: "too large") }
        try fm.removeItem(at: sparse)
        print("PASS: type/mode changes, corrupt data, identity/path/link isolation, lease and backup-only deletion")
    }
}
