import Foundation
import Darwin

@main struct ManagedStorageTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "ManagedStorageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("iosvm-storage-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
            }
            try? fm.removeItem(at: root)
        }
        // A refused cleanup must preserve a completed artifact and not throw or block a later import.
        let locked = root.appendingPathComponent("LockedInbox")
        try fm.createDirectory(at: locked, withIntermediateDirectories: false)
        let ipa = locked.appendingPathComponent("ReadOnly.ipa")
        try Data("source".utf8).write(to: ipa)
        let completed = root.appendingPathComponent("Completed.zip")
        try Data("completed".utf8).write(to: completed)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        try require(!LCManagedDirectory.cleanup(ipa), "refused cleanup was reported as removed")
        try require(try Data(contentsOf: completed) == Data("completed".utf8), "cleanup damaged completed output")
        try require(try Data(contentsOf: ipa) == Data("source".utf8), "refused cleanup damaged source")
        let first = try LCManagedDirectory.temporaryWorkspace()
        let second = try LCManagedDirectory.temporaryWorkspace()
        defer { LCManagedDirectory.cleanup(first); LCManagedDirectory.cleanup(second) }
        try require(first != second, "two imports share a workspace")
        try fm.createDirectory(at: first.appendingPathComponent("Payload"), withIntermediateDirectories: false)
        try Data("stale".utf8).write(to: first.appendingPathComponent("Payload/old"))
        try require(!(try fm.contentsOfDirectory(atPath: second.path)).contains("Payload"), "stale extraction contaminated next import")
        try require(LCManagedDirectory.cleanup(second), "owned workspace cleanup failed")
        try require(LCManagedDirectory.cleanup(second), "missing cleanup is not idempotent")

        let settings = root.appendingPathComponent("iOSVM/NetworkSettings")
        try fm.createDirectory(at: settings, withIntermediateDirectories: true)
        let original = Data("{\"capture\":true}".utf8)
        let file = settings.appendingPathComponent("original.json")
        try original.write(to: file)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: settings.path)
        try require(!fm.isWritableFile(atPath: settings.path), "Run these tests as an ordinary user")
        guard let backup = try LCManagedDirectory.ensureWritable(settings, inside: root) else { throw NSError(domain: "test", code: 1) }
        try require(try Data(contentsOf: file) == original, "migration changed existing settings")
        try require(try Data(contentsOf: backup.appendingPathComponent("original.json")) == original, "original backup changed")
        let saved = settings.appendingPathComponent("new.json")
        try Data("first".utf8).write(to: saved, options: .atomic)
        try Data("second".utf8).write(to: saved, options: .atomic)
        try require(try Data(contentsOf: saved) == Data("second".utf8), "atomic replacement failed")
        try require(try LCManagedDirectory.ensureWritable(settings, inside: root) == nil, "working directory migrated twice")
        try require(!(try fm.contentsOfDirectory(atPath: settings.path)).contains(where: { $0.hasPrefix(".write-probe-") }), "write probe leaked")

        let unsafe = root.appendingPathComponent("Unsafe")
        try fm.createDirectory(at: unsafe, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: unsafe.appendingPathComponent("link"), withDestinationURL: saved)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unsafe.path)
        do { try LCManagedDirectory.ensureWritable(unsafe, inside: root); throw NSError(domain: "accepted unsafe directory", code: 1) }
        catch let error as NSError { try require(error.domain == "IOSVMManagedDirectory", "unexpected unsafe-copy failure") }
        try require(fm.fileExists(atPath: unsafe.appendingPathComponent("link").path), "failed migration damaged original")
        try require(try Data(contentsOf: saved) == Data("second".utf8), "migration followed symlink")
        try require(!(try fm.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".Unsafe-repair-") }), "staging leaked after failure")

        let versioned = root.appendingPathComponent("iOSVM/NetworkSettingsV2")
        try require(try LCManagedDirectory.migrateLegacy(settings, to: versioned, inside: root), "legacy copy was not published")
        try require(try Data(contentsOf: versioned.appendingPathComponent("original.json")) == original, "legacy copy changed configuration")
        try Data("updated".utf8).write(to: versioned.appendingPathComponent("original.json"), options: .atomic)
        try require(try !LCManagedDirectory.migrateLegacy(settings, to: versioned, inside: root), "retry overwrote new settings")
        try require(try Data(contentsOf: versioned.appendingPathComponent("original.json")) == Data("updated".utf8), "updated settings were overwritten by legacy")
        try require(try Data(contentsOf: file) == original, "legacy source was changed")

        let chainRoot = root.appendingPathComponent("Nested")
        let chainLeaf = chainRoot.appendingPathComponent("Frida/Scripts")
        try fm.createDirectory(at:chainLeaf,withIntermediateDirectories:true)
        let chainFile = chainLeaf.appendingPathComponent("fixture.js")
        try Data("chain".utf8).write(to:chainFile)
        try fm.setAttributes([.posixPermissions:0o555],ofItemAtPath:chainRoot.path)
        try LCManagedDirectory.ensureWritableChain(chainLeaf,inside:root)
        try require(try Data(contentsOf:chainFile) == Data("chain".utf8), "nested chain repair lost data")
        try require(fm.isWritableFile(atPath:chainLeaf.path), "nested chain remains read-only")
        let tweaks = root.appendingPathComponent("Tweaks")
        let managed = tweaks.appendingPathComponent("iOSVM-Frida-test.app")
        try fm.createDirectory(at: managed, withIntermediateDirectories: true)
        let config = managed.appendingPathComponent("FridaGadget.config")
        let identity = Data("same port and token".utf8); try identity.write(to: config)
        let adopted = try LCFridaWorkspace.locate(base: tweaks, bundle: "test.app", selected: nil)
        try require(adopted.reuseExisting && adopted.destination.path == managed.path, "detached directory was not recovered")
        try require(try Data(contentsOf: config) == identity, "recovery changed connection identity")
        let missing = try LCFridaWorkspace.locate(base: tweaks, bundle: "missing.app", selected: "iOSVM-Frida-missing.app")
        try require(!missing.reuseExisting && missing.source == nil, "missing selected workspace was not recreatable")
        let custom = tweaks.appendingPathComponent("Custom")
        try fm.createDirectory(at: custom, withIntermediateDirectories: true)
        try Data("keep custom plugin".utf8).write(to: custom.appendingPathComponent("custom.dylib"))
        let separate = try LCFridaWorkspace.locate(base: tweaks, bundle: "test.app", selected: "Custom")
        try require(separate.destination.path != managed.path && separate.source?.path == custom.path, "conflicting plugin sets were overwritten")
        let retry = try LCFridaWorkspace.locate(base: tweaks, bundle: "test.app", selected: separate.name)
        try require(retry.name == separate.name, "retry allocated another workspace")
        let link = tweaks.appendingPathComponent("External")
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        do { _ = try LCFridaWorkspace.locate(base: tweaks, bundle: "test.app", selected: "External"); throw NSError(domain: "accepted link", code: 1) }
        catch let error as NSError { try require(error.domain == "IOSVMFridaWorkspace", "unexpected plugin link error") }
        let unused = tweaks.appendingPathComponent("iOSVM-Frida-old.app")
        let stale = tweaks.appendingPathComponent(".frida-version-old")
        try fm.createDirectory(at: unused, withIntermediateDirectories: false)
        try fm.createDirectory(at: stale, withIntermediateDirectories: false)
        let cleanup = try LCFridaWorkspace.unusedFolders(
            bases: [tweaks],
            referenced: [managed.lastPathComponent, "Custom"]
        )
        try require(Set(cleanup.map(\.lastPathComponent)) == Set([unused.lastPathComponent, stale.lastPathComponent]),
                    "unused Gadget cleanup selected the current or unrelated directory")
        print("PASS: refused cleanup preserves completed output; isolated import workspaces; read-only settings migrate with intact backup; atomic saves and retry work; failed migration preserves originals; Frida recovers detached/missing workspaces and preserves conflicting plugin sets")
        print("PASS: unused Gadget/staging directory scan honors references and ignores unrelated folders")
    }
}
