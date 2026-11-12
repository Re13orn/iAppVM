import Foundation
import CryptoKit
import Darwin

/// Ordinary-file snapshots. Backups never live inside the guest container.
/// Publication and restoration use a same-volume atomic directory swap; a journal
/// identifies both directory inodes so an interrupted swap is never guessed at.
enum LCSandboxBackupStore {
    static let maximumEntries = 50_000
    static let maximumBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let maximumBackups = 32
    static let excludedRoots = ["LCContainerInfo.plist", "iOSVMLaunch.json", ".com.apple.mobile_container_manager.metadata.plist", "Library/iOSVM"]
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    static func fail(_ message: String) -> Failure { Failure(message: message) }
    struct Context: Sendable {
        let owner: String
        let container: String
        let root: URL
        let home: URL
        init(owner: String, container: String, root: URL, storage: URL) throws {
            guard component(owner), component(container) else { throw fail("App 或容器标识无效。") }
            guard try kind(root) == "directory" else { throw fail("数据容器必须是实际目录，不能是链接。") }
            self.owner = owner; self.container = container
            self.root = root.standardizedFileURL.resolvingSymlinksInPath()
            let canonicalStorage = storage.standardizedFileURL.resolvingSymlinksInPath()
            guard !canonicalStorage.path.hasPrefix(self.root.path + "/"), canonicalStorage != self.root else { throw fail("备份目录不能位于目标沙盒内。") }
            home = storage.standardizedFileURL.appendingPathComponent(digest(Data((owner + "\0" + container).utf8)))
        }
    }
    struct Entry: Codable, Equatable, Sendable {
        var path: String
        var kind: String
        var size: Int64
        var hash: String?
        var modified: Date
        var mode: UInt16
        var protection: String? = nil
    }
    struct Manifest: Codable, Identifiable, Sendable {
        var version = 1
        var id = UUID().uuidString
        var owner: String
        var container: String
        var name: String
        var created = Date()
        var reason: String = "manual"
        var entries: [Entry]
        var skipped: [String]
        var bytes: Int64 { entries.reduce(0) { $0 + $1.size } }
        var files: Int { entries.filter { $0.kind == "file" }.count }
    }
    /// The list retains summaries, not every file index from every backup.
    struct Summary: Identifiable, Sendable {
        var id: String
        var name: String
        var created: Date
        var reason: String
        var bytes: Int64
        var files: Int
        init(_ manifest: Manifest) {
            id = manifest.id; name = manifest.name; created = manifest.created
            reason = manifest.reason; bytes = manifest.bytes; files = manifest.files
        }
    }
    struct Change: Identifiable, Sendable {
        var path: String
        var status: String
        var before: Entry?
        var after: Entry?
        var id: String { path }
    }
    struct Comparison: Sendable {
        var baselineFingerprint: String
        var changes: [Change]
        var current: [Entry]
        var skipped: [String]
        var added: Int { changes.filter { $0.status == "新增" }.count }
        var modified: Int { changes.filter { $0.status == "修改" }.count }
        var deleted: Int { changes.filter { $0.status == "删除" }.count }
    }
    private struct Journal: Codable {
        var version = 1
        var owner: String
        var container: String
        var stage: String
        var originalInode: UInt64
        var replacementInode: UInt64
        var rescueID: String
    }
    private static let fm = FileManager.default
    private static let leaseLock = NSLock()
    private static var leases = Set<String>()
    final class Lease: @unchecked Sendable {
        private let key: String
        init(_ key: String) { self.key = key }
        deinit { leaseLock.lock(); leases.remove(key); leaseLock.unlock() }
    }
    static func reserve(_ root: URL) throws -> Lease {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        leaseLock.lock(); defer { leaseLock.unlock() }
        guard leases.insert(key).inserted else { throw fail("此容器正在备份、比较、恢复或准备启动，请稍后重试。") }
        return Lease(key)
    }
    static func busy(_ root: URL) -> Bool {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        leaseLock.lock(); defer { leaseLock.unlock() }; return leases.contains(key)
    }
    static func pending(_ context: Context) -> Bool { (try? attributes(context.home.appendingPathComponent("pending-restore.json"))) != nil }
    private static func component(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0") && value.utf8.count < 256
    }
    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component(String($0)) }
    }
    private static func excluded(_ path: String) -> Bool { excludedRoots.contains { path == $0 || path.hasPrefix($0 + "/") } }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func attributes(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw fail("无法读取文件属性：" + url.lastPathComponent) }
        return value
    }
    private static func kind(_ url: URL) throws -> String {
        let value = try attributes(url)
        switch value.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): return "file"
        case mode_t(S_IFDIR): return "directory"
        case mode_t(S_IFLNK): return "link"
        default: return "special"
        }
    }
    private static func safeDirectory(_ url: URL, create: Bool = false) throws {
        if create && !fm.fileExists(atPath: url.path) {
            var parent = url.deletingLastPathComponent()
            while !fm.fileExists(atPath: parent.path) { parent.deleteLastPathComponent() }
            try safeDirectory(parent)
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard try kind(url) == "directory", url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw fail("目录包含链接或无法安全访问。") }
    }
    /// Open the final component without following links, and detect mutation while streaming.
    private static func hashFile(_ source: URL, copyTo: URL? = nil) throws -> (String, Int64) {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw fail("无法读取普通文件：" + source.lastPathComponent) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size <= maximumBytes else { throw fail("文件类型或大小不受支持。") }
        var output: FileHandle?
        if let copyTo {
            let target = open(copyTo.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard target >= 0 else { throw fail("无法写入备份文件，原文件未改动。") }
            output = FileHandle(fileDescriptor: target, closeOnDealloc: true)
            #if os(iOS)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: copyTo.path)
            #endif
        }
        defer { try? output?.close() }
        var hash = SHA256(), count: Int64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            count += Int64(data.count)
            guard count <= maximumBytes else { throw fail("单次备份最多支持 8 GiB 普通文件。") }
            hash.update(data: data); try output?.write(contentsOf: data)
        }
        try output?.synchronize()
        var after = stat(); guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_size == count,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw fail("文件在读取时发生变化，请关闭 App 后重新操作。") }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
    private static func scan(_ root: URL, copyTo: URL? = nil) throws -> (entries: [Entry], skipped: [String]) {
        try safeDirectory(root)
        var entries: [Entry] = [], skipped: [String] = [], bytes: Int64 = 0
        func walk(_ directory: URL, relative: String) throws {
            try safeDirectory(directory)
            for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let path = relative.isEmpty ? item.lastPathComponent : relative + "/" + item.lastPathComponent
                guard validPath(path), entries.count + skipped.count < maximumEntries else { throw fail("目录路径无效或条目超过 50,000 项。") }
                if excluded(path) { skipped.append(path); continue }
                let type = try kind(item)
                guard type == "file" || type == "directory" else { skipped.append(path); continue }
                let a = try attributes(item)
                var entry = Entry(path: path, kind: type, size: 0, hash: nil,
                                  modified: Date(timeIntervalSince1970: Double(a.st_mtimespec.tv_sec) + Double(a.st_mtimespec.tv_nsec) / 1e9), mode: UInt16(a.st_mode & 0o777))
                #if os(iOS)
                let protection = try fm.attributesOfItem(atPath: item.path)[.protectionKey]
                entry.protection = (protection as? FileProtectionType)?.rawValue ?? protection as? String
                #endif
                let target = copyTo?.appendingPathComponent(path)
                if type == "directory" {
                    if let target { try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
                    entries.append(entry); try walk(item, relative: path)
                } else {
                    let result = try hashFile(item, copyTo: target)
                    entry.hash = result.0; entry.size = result.1; bytes += result.1
                    guard bytes <= maximumBytes else { throw fail("单次备份最多支持 8 GiB 普通文件。") }
                    entries.append(entry)
                }
            }
        }
        try walk(root, relative: "")
        return (entries.sorted { $0.path < $1.path }, skipped.sorted())
    }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 32 * 1024 * 1024 else { throw fail("备份索引超过 32 MiB，未发布备份。") }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func fingerprint(_ manifest: Manifest) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(manifest))
    }
    private static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        guard try kind(url) == "file", try attributes(url).st_size <= 32 * 1024 * 1024 else { throw fail("备份索引不是有效的普通文件。") }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private static func folder(_ id: String, _ context: Context) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw fail("备份标识无效。") }
        try safeDirectory(context.home)
        let url = context.home.appendingPathComponent(id); try safeDirectory(url); return url
    }
    private static func validate(_ manifest: Manifest, _ context: Context) throws {
        guard manifest.version == 1, UUID(uuidString: manifest.id) != nil, manifest.owner == context.owner, manifest.container == context.container,
              manifest.entries.count <= maximumEntries, manifest.skipped.count <= maximumEntries,
              Set(manifest.entries.map(\.path)).count == manifest.entries.count else { throw fail("备份归属或索引不匹配，已停止操作。") }
        var bytes: Int64 = 0
        let map = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.path, $0) })
        for entry in manifest.entries {
            guard validPath(entry.path), !excluded(entry.path), ["file", "directory"].contains(entry.kind), entry.size >= 0,
                  entry.size <= maximumBytes, entry.mode <= 0o777 else { throw fail("备份包含不安全的路径或条目。") }
            if let protection = entry.protection, !["NSFileProtectionNone", "NSFileProtectionComplete", "NSFileProtectionCompleteUnlessOpen", "NSFileProtectionCompleteUntilFirstUserAuthentication"].contains(protection) { throw fail("文件保护属性无效。") }
            if entry.kind == "file" {
                guard let hash = entry.hash, hash.count == 64, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw fail("文件摘要无效。") }
                bytes += entry.size; guard bytes <= maximumBytes else { throw fail("备份大小超过限制。") }
            } else if entry.hash != nil || entry.size != 0 { throw fail("目录索引无效。") }
            var parent = (entry.path as NSString).deletingLastPathComponent
                while !parent.isEmpty {
                guard map[parent]?.kind == "directory" else { throw fail("备份目录层级无效。") }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }
    static func list(_ context: Context) throws -> [Summary] {
        try safeDirectory(context.home, create: true)
        return try fm.contentsOfDirectory(at: context.home, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { url in
            Summary(try load(url.lastPathComponent, context))
        }.sorted { $0.created > $1.created }
    }
    static func load(_ id: String, _ context: Context) throws -> Manifest {
        let m = try read(Manifest.self, at: folder(id, context).appendingPathComponent("manifest.json"))
        try validate(m, context); guard m.id == id else { throw fail("备份标识不匹配。") }; return m
    }
    /// Caller holds the container lease and has verified that no guest is running.
    static func create(_ context: Context, name: String, reason: String = "manual") throws -> Manifest {
        guard !pending(context) else { throw fail("请先完成上次未结束的恢复。") }
        guard try list(context).count < maximumBackups else {
            throw fail("此容器已有 \(maximumBackups) 份备份。请先删除不再需要的备份，再创建新的备份。")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw fail("备份名称需为 1–80 个字符。") }
        try safeDirectory(context.home, create: true)
        let id = UUID().uuidString, stage = context.home.appendingPathComponent(".creating-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let files = stage.appendingPathComponent("files")
        try fm.createDirectory(at: files, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let snapshot = try scan(context.root, copyTo: files)
        let recheck = try scan(context.root)
        guard snapshot.entries == recheck.entries, snapshot.skipped == recheck.skipped else { throw fail("沙盒在备份时发生变化，未发布备份，请关闭 App 后重试。") }
        var manifest = Manifest(owner: context.owner, container: context.container, name: name, entries: snapshot.entries, skipped: snapshot.skipped)
        manifest.id = id; manifest.reason = reason
        try validate(manifest, context)
        try write(manifest, to: stage.appendingPathComponent("manifest.json"))
        try fm.moveItem(at: stage, to: context.home.appendingPathComponent(id))
        return manifest
    }
    static func compare(_ id: String, _ context: Context) throws -> Comparison {
        guard !pending(context) else { throw fail("请先完成上次未结束的恢复。") }
        let original = try load(id, context), current = try scan(context.root)
        let a = Dictionary(uniqueKeysWithValues: original.entries.map { ($0.path, $0) }), b = Dictionary(uniqueKeysWithValues: current.entries.map { ($0.path, $0) })
        var changes: [Change] = []
        for path in Set(a.keys).union(b.keys).sorted() {
            let old = a[path], new = b[path]
            if old == nil { changes.append(Change(path: path, status: "新增", before: nil, after: new)) }
            else if new == nil { changes.append(Change(path: path, status: "删除", before: old, after: nil)) }
            else if old!.kind != new!.kind || old!.hash != new!.hash || old!.mode != new!.mode || old!.protection != new!.protection {
                changes.append(Change(path: path, status: "修改", before: old, after: new))
            }
        }
        return Comparison(baselineFingerprint: try fingerprint(original), changes: changes, current: current.entries, skipped: Array(Set(original.skipped + current.skipped)).sorted())
    }
    static func delete(_ id: String, _ context: Context) throws {
        guard !pending(context) else { throw fail("恢复未完成，暂时不能删除备份。") }
        _ = try load(id, context); try fm.removeItem(at: folder(id, context))
    }
    private static func inode(_ url: URL) throws -> UInt64 { UInt64(try attributes(url).st_ino) }
    private static func requireRestorableOwnership(_ url: URL) throws {
        let a = try attributes(url)
        let immutable = UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(SF_APPEND)
        guard a.st_uid == getuid(), a.st_flags & immutable == 0 else {
            throw fail("容器含有不同用户创建或带保护标记的文件；可读取的文件仍可备份，本次不执行恢复。")
        }
    }
    /// Only call on a newly created staging directory, or the old directory whose
    /// inode and rescue snapshot were verified against the restore journal.
    private static func removeDisposableTree(_ url: URL) throws {
        if try kind(url) == "directory" {
            try safeDirectory(url)
            guard try attributes(url).st_uid == getuid() else { throw fail("临时目录不属于当前进程，未清理。") }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try removeDisposableTree(child) }
        }
        try fm.removeItem(at: url)
    }
    /// Preserve excluded host controls and links verbatim; never traverse their targets.
    private struct PreservationBudget { var entries = 0; var bytes: Int64 = 0 }
    private static func preserve(_ source: URL, to destination: URL, budget: inout PreservationBudget) throws {
        try requireRestorableOwnership(source)
        budget.entries += 1
        guard budget.entries <= maximumEntries, source.path.utf8.count <= 4096 else { throw fail("排除项过多或路径过深，未执行恢复。") }
        switch try kind(source) {
        case "file":
            let result = try hashFile(source, copyTo: destination); budget.bytes += result.1
            guard budget.bytes <= maximumBytes else { throw fail("需要保留的排除项超过 8 GiB，未执行恢复。") }
        case "link": try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: fm.destinationOfSymbolicLink(atPath: source.path))
        case "directory":
            try safeDirectory(source)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) { try preserve(child, to: destination.appendingPathComponent(child.lastPathComponent), budget: &budget) }
        default: throw fail("存在无法保留的特殊文件，未恢复：" + source.lastPathComponent)
        }
        if try kind(source) != "link" {
            let attrs = try fm.attributesOfItem(atPath: source.path)
            try fm.setAttributes([.posixPermissions: attrs[.posixPermissions] ?? 0o600,
                                  .modificationDate: attrs[.modificationDate] ?? Date()], ofItemAtPath: destination.path)
            #if os(iOS)
            if let protection = attrs[.protectionKey] { try fm.setAttributes([.protectionKey: protection], ofItemAtPath: destination.path) }
            #endif
        }
    }
    /// Detect concurrent edits to excluded controls without saving their content
    /// in a manifest. Link destinations are hashed as text, never dereferenced.
    private static func preservedFingerprint(_ source: URL) throws -> String {
        var hash = SHA256(), budget = PreservationBudget()
        func walk(_ url: URL, relative: String) throws {
            budget.entries += 1
            guard budget.entries <= maximumEntries, relative.utf8.count <= 4096 else { throw fail("排除项超出校验限制。") }
            let type = try kind(url), a = try attributes(url)
            var record = [relative, type, String(a.st_mode & 0o777)]
            switch type {
            case "file":
                let result = try hashFile(url); budget.bytes += result.1
                guard budget.bytes <= maximumBytes else { throw fail("排除项超出校验限制。") }
                record.append(result.0)
            case "link": record.append(try fm.destinationOfSymbolicLink(atPath: url.path))
            case "directory": try safeDirectory(url)
            default: throw fail("无法校验特殊文件，未执行恢复。")
            }
            hash.update(data: try JSONEncoder().encode(record))
            if type == "directory" {
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try walk(child, relative: relative + "/" + child.lastPathComponent)
                }
            }
        }
        try walk(source, relative: "")
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Restore requires the exact comparison shown in the user's confirmation.
    /// testStopAfterSwap simulates process death, and is never supplied by UI code.
    static func restore(_ id: String, _ context: Context, expected: Comparison, testStopAfterSwap: Bool = false, testStopBeforeSwap: Bool = false) throws -> Manifest {
        guard !pending(context) else { throw fail("请先完成上次未结束的恢复。") }
        let now = try compare(id, context)
        guard now.baselineFingerprint == expected.baselineFingerprint, now.current == expected.current,
              now.changes.map(\.path) == expected.changes.map(\.path), now.skipped == expected.skipped else { throw fail("确认后沙盒或备份已变化，请刷新差异后重新确认。") }
        let manifest = try load(id, context), backup = try folder(id, context).appendingPathComponent("files")
        guard try fingerprint(manifest) == expected.baselineFingerprint else { throw fail("备份已变化，请重新比较并确认。") }
        let verified = try scan(backup)
        guard verified.entries.map({ ($0.path, $0.kind, $0.hash, $0.size) }).elementsEqual(manifest.entries.map({ ($0.path, $0.kind, $0.hash, $0.size) }), by: { $0 == $1 }), verified.skipped.isEmpty else { throw fail("备份内容校验失败，原沙盒未改动。") }
        // Verify ownership before renaming an entire managed container directory.
        try requireRestorableOwnership(context.root)
        for entry in now.current { try requireRestorableOwnership(context.root.appendingPathComponent(entry.path)) }
        let rescue = try create(context, name: "恢复前自动备份", reason: "before-restore")
        let stageName = ".iappvm-restore-" + UUID().uuidString
        let stage = context.root.deletingLastPathComponent().appendingPathComponent(stageName)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var journalPublished = false
        defer { if !journalPublished { try? removeDisposableTree(stage) } }
        // Rebuild from verified regular files rather than trusting an archive extractor.
        for entry in manifest.entries.sorted(by: { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }) {
            let to = stage.appendingPathComponent(entry.path)
            if entry.kind == "directory" { try fm.createDirectory(at: to, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            else {
                let result = try hashFile(backup.appendingPathComponent(entry.path), copyTo: to)
                guard result.0 == entry.hash, result.1 == entry.size else { throw fail("备份文件在恢复准备时发生变化。") }
            }
        }
        let live = try scan(context.root)
        guard live.entries == expected.current else { throw fail("恢复准备期间沙盒已变化，请重新比较并确认。") }
        var preservationBudget = PreservationBudget()
        var preserved: [String: String] = [:]
        for path in live.skipped {
            let target = stage.appendingPathComponent(path)
            guard !fm.fileExists(atPath: target.path) else { throw fail("备份路径与当前排除项冲突：" + path) }
            let parent = target.deletingLastPathComponent()
            // A non-directory ancestor indicates a file/link type conflict, never follow it.
            var ancestor = parent
            while ancestor.path != stage.path {
                guard ancestor.path.hasPrefix(stage.path + "/") else { throw fail("恢复目录层级无效。") }
                if fm.fileExists(atPath: ancestor.path) { try safeDirectory(ancestor) }
                ancestor.deleteLastPathComponent()
            }
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try preserve(context.root.appendingPathComponent(path), to: target, budget: &preservationBudget)
            let fingerprint = try preservedFingerprint(context.root.appendingPathComponent(path))
            guard try preservedFingerprint(target) == fingerprint else { throw fail("需要保留的控制信息正在变化，未执行恢复。") }
            preserved[path] = fingerprint
        }
        for entry in manifest.entries.sorted(by: { $0.path.count > $1.path.count }) {
            try fm.setAttributes([.posixPermissions: NSNumber(value: entry.mode), .modificationDate: entry.modified], ofItemAtPath: stage.appendingPathComponent(entry.path).path)
            #if os(iOS)
            if let protection = entry.protection { try fm.setAttributes([.protectionKey: FileProtectionType(rawValue: protection)], ofItemAtPath: stage.appendingPathComponent(entry.path).path) }
            #endif
        }
        let rootMode = try attributes(context.root).st_mode & 0o777
        try fm.setAttributes([.posixPermissions: NSNumber(value: rootMode)], ofItemAtPath: stage.path)
        #if os(iOS)
        if let protection = try fm.attributesOfItem(atPath: context.root.path)[.protectionKey] { try fm.setAttributes([.protectionKey: protection], ofItemAtPath: stage.path) }
        #endif
        let recheck = try scan(context.root)
        guard recheck.entries == expected.current, recheck.skipped == live.skipped else { throw fail("沙盒已变化，未执行恢复。") }
        for (path, fingerprint) in preserved {
            guard try preservedFingerprint(context.root.appendingPathComponent(path)) == fingerprint else { throw fail("当前容器管理信息已变化，未执行恢复。") }
        }
        let journal = Journal(owner: context.owner, container: context.container, stage: stageName, originalInode: try inode(context.root), replacementInode: try inode(stage), rescueID: rescue.id)
        try write(journal, to: context.home.appendingPathComponent("pending-restore.json")); journalPublished = true
        #if IOSVM_TESTING || IOSVM_BACKUP_TESTING
        if testStopBeforeSwap { throw fail("Simulated interruption before swap") }
        #endif
        guard renameatx_np(AT_FDCWD, context.root.path, AT_FDCWD, stage.path, UInt32(RENAME_SWAP)) == 0 else {
            // Atomic swap failed: root was not changed. Journal still enables safe cleanup.
            throw fail("文件系统未能原子切换容器，原数据保持不变。请完成恢复整理后重试。")
        }
        #if IOSVM_TESTING || IOSVM_BACKUP_TESTING
        if testStopAfterSwap { throw fail("Simulated interruption after swap") }
        #endif
        try recover(context)
        return rescue
    }
    /// Idempotent reconciliation by inode identity, including death between swap and journal update.
    static func recover(_ context: Context) throws {
        guard pending(context) else { return }
        let url = context.home.appendingPathComponent("pending-restore.json")
        let j = try read(Journal.self, at: url)
        guard j.version == 1, j.owner == context.owner, j.container == context.container,
              j.stage.hasPrefix(".iappvm-restore-"), UUID(uuidString: String(j.stage.dropFirst(".iappvm-restore-".count))) != nil else { throw fail("恢复记录无效，请保留当前数据与备份，不执行自动整理。") }
        let stage = context.root.deletingLastPathComponent().appendingPathComponent(j.stage)
        try safeDirectory(context.root)
        let current = try inode(context.root)
        // Cleanup may already have succeeded before process death; the root identity
        // still proves which version is installed, so removing the journal is safe.
        if fm.fileExists(atPath: stage.path) {
            try safeDirectory(stage)
            let other = try inode(stage)
            guard (current == j.originalInode && other == j.replacementInode) ||
                  (current == j.replacementInode && other == j.originalInode) else { throw fail("容器目录已被其他操作替换，已停止恢复整理。") }
            _ = try load(j.rescueID, context)
            try removeDisposableTree(stage)
        } else {
            guard current == j.originalInode || current == j.replacementInode else { throw fail("无法确认恢复结果，请保留备份。") }
        }
        try fm.removeItem(at: url)
    }
}
