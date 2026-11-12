import Foundation
import Darwin

/// Repair managed settings imported by desktop tooling with a different POSIX owner.
/// The old directory remains as a backup; no chown, elevated access or wider mode is required.
enum LCManagedDirectory {
    private static let lock = NSRecursiveLock()

    /// Each import/download owns its workspace; stale or foreign-owned Payloads are never reused.
    static func temporaryWorkspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iOSVM-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// Only for disposable artifacts. Failure must not change the outcome of completed work.
    /// Return the result for diagnostics without hiding failures of user-requested deletion.
    @discardableResult
    static func cleanup(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { return true }
            // Avoid logging file contents, proxy credentials or full container paths.
            NSLog("[iOSVM] Disposable cleanup retained %@ (%@/%ld)", url.lastPathComponent, error.domain, error.code)
            return false
        }
    }

    /// A sandbox may forbid renaming a foreign-owned directory even when its parent is writable.
    /// Publish an owned copy at a new path and retain the entire legacy directory unchanged.
    @discardableResult
    static func migrateLegacy(_ legacy: URL, to directory: URL, inside root: URL) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try validate(legacy, inside: root)
        try validate(directory, inside: root)
        if fm.fileExists(atPath: directory.path) {
            try ensureWritable(directory, inside: root)
            return false
        }
        guard fm.fileExists(atPath: legacy.path) else {
            try ensureWritable(directory, inside: root)
            return false
        }
        guard try fm.attributesOfItem(atPath: legacy.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw failure("旧配置路径不是实际目录，未进行迁移。")
        }
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = parent.appendingPathComponent("." + directory.lastPathComponent + "-migration-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        for source in try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
            try copy(source, to: stage.appendingPathComponent(source.lastPathComponent))
        }
        try fm.moveItem(at: stage, to: directory)
        return true
    }

    private static func validate(_ directory: URL, inside root: URL) throws {
        let root = root.standardizedFileURL
        let directory = directory.standardizedFileURL
        let prefix = root.path + "/"
        guard directory.path.hasPrefix(prefix) else { throw failure("配置目录超出宿主存储范围。") }
        let relative = String(directory.path.dropFirst(prefix.count))
        let expected = root.resolvingSymlinksInPath().appendingPathComponent(relative).standardizedFileURL
        guard directory.resolvingSymlinksInPath() == expected else { throw failure("配置目录包含未经允许的链接。") }
    }

    /// Repair nested managed paths from the sandbox root downward. A read-only leaf is
    /// not sufficient if one of its parents is still owned by an older app installation.
    static func ensureWritableChain(_ directory: URL, inside root: URL) throws {
        let root = root.standardizedFileURL
        let directory = directory.standardizedFileURL
        let prefix = root.path + "/"
        guard directory.path.hasPrefix(prefix) else { throw failure("配置目录超出宿主存储范围。") }
        let relative = String(directory.path.dropFirst(prefix.count))
        var current = root
        for component in relative.split(separator: "/") {
            guard !component.isEmpty, component != ".", component != ".." else { throw failure("配置目录名无效。") }
            current.appendPathComponent(String(component), isDirectory: true)
            _ = try ensureWritable(current, inside: root)
        }
    }

    @discardableResult
    static func ensureWritable(_ directory: URL, inside root: URL) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let root = root.standardizedFileURL
        let directory = directory.standardizedFileURL
        let prefix = root.path + "/"
        guard directory.path.hasPrefix(prefix) else { throw failure("配置目录超出宿主存储范围。") }
        let relative = String(directory.path.dropFirst(prefix.count))
        let expected = root.resolvingSymlinksInPath().appendingPathComponent(relative).standardizedFileURL
        guard directory.resolvingSymlinksInPath() == expected else { throw failure("配置目录包含未经允许的链接。") }
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return nil
        }
        let attrs = try fm.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw failure("配置路径不是实际目录。") }
        if (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), fm.isWritableFile(atPath: directory.path) {
            // POSIX writability is not enough: an app or app-group sandbox can deny the
            // actual operation even when stat reports the directory as writable.
            let probe = directory.appendingPathComponent(".write-probe-" + UUID().uuidString, isDirectory: true)
            do {
                try fm.createDirectory(at: probe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try fm.removeItem(at: probe)
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                return nil
            } catch {
                // Fall through and publish a directory owned by this process.
            }
        }
        let nonce = UUID().uuidString
        let stage = parent.appendingPathComponent("." + directory.lastPathComponent + "-repair-" + nonce)
        let backup = parent.appendingPathComponent("." + directory.lastPathComponent + "-backup-" + nonce)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        // Complete the copy before renaming anything. A copy error leaves the original untouched.
        for source in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try copy(source, to: stage.appendingPathComponent(source.lastPathComponent))
        }
        try fm.moveItem(at: directory, to: backup)
        do { try fm.moveItem(at: stage, to: directory) }
        catch {
            do { try fm.moveItem(at: backup, to: directory) }
            catch let rollback { throw failure("配置目录恢复失败，原文件保存在 \(backup.lastPathComponent)：\(rollback.localizedDescription)") }
            throw error
        }
        return backup
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: source.path)
        switch attrs[.type] as? FileAttributeType {
        case .typeDirectory:
            try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copy(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        case .typeRegular:
            try fm.copyItem(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        default:
            throw failure("配置目录包含链接或特殊文件；已保留原目录，未进行迁移。")
        }
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "IOSVMManagedDirectory", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
