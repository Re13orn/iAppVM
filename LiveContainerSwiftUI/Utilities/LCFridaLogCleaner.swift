import Foundation

enum LCFridaLogBoundary {
    static func directory(_ url: URL, inside root: URL) throws -> URL {
        let (candidate, expected) = try relative(url, root: root)
        guard FileManager.default.fileExists(atPath: candidate.path) else { throw failure("日志目录不存在。") }
        let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              candidate.resolvingSymlinksInPath().standardizedFileURL == expected else {
            throw failure("日志目录包含未经允许的链接或不是实际目录。")
        }
        return candidate
    }

    static func regularFile(_ url: URL, inside root: URL) throws -> URL {
        let (candidate, expected) = try relative(url, root: root)
        let parent = candidate.deletingLastPathComponent()
        _ = try directory(parent, inside: root)
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              candidate.resolvingSymlinksInPath().standardizedFileURL == expected else {
            throw failure("日志文件不是普通文件或包含未经允许的链接。")
        }
        return candidate
    }

    static func readData(_ url: URL, inside root: URL, maximumBytes: Int) throws -> Data {
        let file = try regularFile(url, inside: root)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法安全打开日志文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw failure("日志文件大小无效。")
        }
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= maximumBytes else { throw failure("日志文件读取超过限制。") }
        return data
    }

    static func readTail(_ url: URL, inside root: URL, limit: Int) throws -> Data {
        let file = try regularFile(url, inside: root)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法安全打开日志文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw failure("日志文件已不是普通文件。")
        }
        let end = try handle.seekToEnd()
        let start = end > UInt64(limit) ? end - UInt64(limit) : 0
        try handle.seek(toOffset: start)
        return try handle.readToEnd() ?? Data()
    }

    static func readRange(_ url: URL, inside root: URL, offset: UInt64, limit: Int) throws -> Data {
        let file = try regularFile(url, inside: root)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法安全打开日志文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw failure("日志文件已不是普通文件。")
        }
        guard offset <= UInt64(info.st_size) else { throw failure("日志文件在读取期间被替换。") }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: limit) ?? Data()
    }

    private static func relative(_ url: URL, root: URL) throws -> (URL, URL) {
        let root = root.standardizedFileURL
        let candidate = url.standardizedFileURL
        let prefix = root.path + "/"
        guard candidate.path.hasPrefix(prefix) else { throw failure("日志路径超出当前 App 容器。") }
        let relative = String(candidate.path.dropFirst(prefix.count))
        let expected = root.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(relative).standardizedFileURL
        return (candidate, expected)
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "IOSVMFridaLogs", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

enum LCFridaLogCleaner {
    static func clearSession(root: URL, folder: URL, source: LCFridaLogSource) throws -> Int {
        let sessions = root.appendingPathComponent("Library/iOSVM/Sessions", isDirectory: true)
        _ = try LCFridaLogBoundary.directory(sessions, inside: root)
        _ = try LCFridaLogBoundary.directory(folder, inside: root)
        try validate(folder, inside: sessions)
        guard folder.lastPathComponent.hasPrefix("session-") else { throw failure("不是有效的调试会话目录。") }
        switch source {
        case .computer:
            throw failure("电脑日志不属于目标控制台会话。")
        case .phone:
            let scripts = folder.appendingPathComponent("phone-scripts", isDirectory: true)
            guard FileManager.default.fileExists(atPath: scripts.path) else { return 0 }
            _ = try LCFridaLogBoundary.directory(scripts, inside: root)
            try validate(scripts, inside: folder)
            var removed = 0
            for entry in try FileManager.default.contentsOfDirectory(at: scripts, includingPropertiesForKeys: nil)
                where entry.pathExtension == "jsonl" {
                _ = try LCFridaLogBoundary.regularFile(entry, inside: root)
                try validate(entry, inside: scripts)
                try FileManager.default.removeItem(at: entry)
                removed += 1
            }
            return removed
        case .process:
            let console = folder.appendingPathComponent("console.log")
            guard FileManager.default.fileExists(atPath: console.path) else { return 0 }
            _ = try LCFridaLogBoundary.regularFile(console, inside: root)
            try validate(console, inside: folder)
            try FileManager.default.removeItem(at: console)
            return 1
        }
    }

    static func clearComputerLog(root: URL, file: URL) throws -> Int {
        let debug = root.appendingPathComponent("Library/iOSVM/Debug", isDirectory: true)
        _ = try LCFridaLogBoundary.directory(debug, inside: root)
        _ = try LCFridaLogBoundary.regularFile(file, inside: root)
        try validate(file, inside: debug)
        let name = file.lastPathComponent
        guard name.hasPrefix("client-"), file.pathExtension == "jsonl" else { throw failure("不是有效的电脑脚本日志。") }
        try FileManager.default.removeItem(at: file)
        return 1
    }

    static func clearAll(root: URL) throws -> Int {
        let fm = FileManager.default
        var removed = 0
        let sessions = root.appendingPathComponent("Library/iOSVM/Sessions", isDirectory: true)
        if fm.fileExists(atPath: sessions.path) {
            _ = try LCFridaLogBoundary.directory(sessions, inside: root)
            for entry in try fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)
                where entry.lastPathComponent.hasPrefix("session-") {
                _ = try LCFridaLogBoundary.directory(entry, inside: root)
                try validate(entry, inside: sessions)
                try fm.removeItem(at: entry)
                removed += 1
            }
        }
        let debug = root.appendingPathComponent("Library/iOSVM/Debug", isDirectory: true)
        if fm.fileExists(atPath: debug.path) {
            _ = try LCFridaLogBoundary.directory(debug, inside: root)
            for entry in try fm.contentsOfDirectory(at: debug, includingPropertiesForKeys: nil)
                where entry.lastPathComponent.hasPrefix("client-") && entry.pathExtension == "jsonl" {
                _ = try LCFridaLogBoundary.regularFile(entry, inside: root)
                try validate(entry, inside: debug)
                try fm.removeItem(at: entry)
                removed += 1
            }
        }
        return removed
    }

    private static func validate(_ entry: URL, inside root: URL) throws {
        let root = root.standardizedFileURL
        let entry = entry.standardizedFileURL
        guard entry.path.hasPrefix(root.path + "/") else { throw failure("日志路径超出当前 App 容器。") }
        let relative = String(entry.path.dropFirst(root.path.count + 1))
        let expected = root.resolvingSymlinksInPath().appendingPathComponent(relative).standardizedFileURL
        guard entry.resolvingSymlinksInPath() == expected else { throw failure("日志路径包含未经允许的链接。") }
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "IOSVMFridaLogs", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
