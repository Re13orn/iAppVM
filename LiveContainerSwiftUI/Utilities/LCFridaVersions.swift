import Foundation
import CryptoKit

enum LCFridaVersions {
    struct Version: Codable, Identifiable, Equatable {
        var id: String
        var version: String
        var sha256: String
        var importedAt: Date
        var builtin: Bool
    }
    static var root: URL { LCPath.docPath.appendingPathComponent("iOSVM/Frida/Versions", isDirectory: true) }
    static var builtin: Version {
        let bundle = Bundle.main.url(forResource: "iOSVMFrida", withExtension: "bundle")
        let info = bundle.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Info.plist")) }
        return Version(id: "builtin", version: info?["CFBundleVersion"] as? String ?? "内置", sha256: "", importedAt: .distantPast, builtin: true)
    }
    static func versions() throws -> [Version] {
        var values = [builtin]
        guard FileManager.default.fileExists(atPath: root.path) else { return values }
        guard LCFridaScriptStore.isManaged(root, inside: LCPath.docPath) else { throw LCFridaScriptStore.failure("版本库包含链接。") }
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: folder.lastPathComponent) != nil else { continue }
            guard LCFridaScriptStore.isManaged(folder, inside: root) else { throw LCFridaScriptStore.failure("版本目录包含链接。") }
            let value = try JSONDecoder().decode(Version.self, from: Data(contentsOf: folder.appendingPathComponent("version.json")))
            guard value.id == folder.lastPathComponent, !value.builtin else { throw LCFridaScriptStore.failure("版本元数据无效。") }
            values.append(value)
        }
        return values
    }
    static func library(_ value: Version) throws -> URL {
        if value.builtin {
            guard let bundle = Bundle.main.url(forResource: "iOSVMFrida", withExtension: "bundle") else { throw LCFridaScriptStore.failure("宿主未包含 Gadget。") }
            return bundle.appendingPathComponent("FridaGadget.dylib")
        }
        guard UUID(uuidString: value.id) != nil else { throw LCFridaScriptStore.failure("版本标识无效。") }
        let file = root.appendingPathComponent(value.id).appendingPathComponent("Gadget.dylib")
        guard LCFridaScriptStore.isManaged(file, inside: root) else { throw LCFridaScriptStore.failure("版本路径包含链接。") }
        let data = try Data(contentsOf: file)
        guard LCFridaScriptStore.digest(data) == value.sha256 else { throw LCFridaScriptStore.failure("Gadget 文件校验失败，请重新导入。") }
        return file
    }
    /// Validate Mach-O without executing it. Official universal assets may include arm64e; select plain arm64.
    static func arm64Slice(_ data: Data, depth: Int = 0) throws -> Data {
        func number(_ offset: Int, big: Bool = false) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw LCFridaScriptStore.failure("Mach-O 文件被截断。") }
            let bytes = data[offset..<offset+4]
            return big ? bytes.reduce(0) { ($0 << 8) | UInt32($1) } : bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard data.count >= 32, data.count <= 128 * 1024 * 1024 else { throw LCFridaScriptStore.failure("Gadget 文件大小无效。") }
        let magic = try number(0)
        if magic == 0xbebafeca { // FAT_MAGIC, 32-bit fat_arch offsets.
            guard depth == 0 else { throw LCFridaScriptStore.failure("不支持嵌套 Universal 文件。") }
            let count = Int(try number(4, big: true))
            guard count <= 16 else { throw LCFridaScriptStore.failure("Universal 架构表无效。") }
            for index in 0..<count {
                let base = 8 + index * 20
                if try number(base, big: true) == 0x0100000c, try number(base+4, big: true) & 0x00ffffff == 0 {
                    let offset = Int(try number(base+8, big: true)), length = Int(try number(base+12, big: true))
                    guard length >= 32, offset >= 8 + count * 20, offset <= data.count, length <= data.count-offset else { throw LCFridaScriptStore.failure("arm64 分片越界。") }
                    return try arm64Slice(data.subdata(in: offset..<offset+length), depth: depth + 1)
                }
            }
        } else if magic == 0xfeedfacf,
                  try number(4) == 0x0100000c, try number(8) & 0x00ffffff == 0,
                  try number(12) == 6 {
            let count = Int(try number(16)), size = Int(try number(20))
            guard count > 0, count <= 4096, size <= data.count - 32 else { throw LCFridaScriptStore.failure("Mach-O load commands 无效。") }
            var cursor = 32, ios = false, dylib = false
            for _ in 0..<count {
                guard cursor <= 32 + size - 8 else { throw LCFridaScriptStore.failure("Load command 被截断。") }
                let command = try number(cursor), length = Int(try number(cursor+4))
                guard length >= 8, length % 4 == 0, length <= 32 + size - cursor else { throw LCFridaScriptStore.failure("Load command 长度无效。") }
                if command == 0x32, length >= 24, try number(cursor+8) == 2 { ios = true }
                if command == 0x25, length >= 16 { ios = true }
                if command == 0x0d, length >= 24 {
                    let offset = Int(try number(cursor+8))
                    guard offset >= 24, offset < length, data[(cursor+offset)..<(cursor+length)].contains(0) else { throw LCFridaScriptStore.failure("Dylib 标识命令无效。") }
                    dylib = true
                }
                cursor += length
            }
            guard cursor == 32 + size, ios, dylib else { throw LCFridaScriptStore.failure("文件不是带有效标识的 iOS 动态库。") }
            return data
        }
        throw LCFridaScriptStore.failure("请选择含普通 arm64 架构的 iOS Gadget dylib；不支持 xz 压缩包、arm64e-only 或可执行文件。")
    }
    static func importFile(_ url: URL, version: String) throws {
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.utf8.count <= 32, version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { throw LCFridaScriptStore.failure("请输入版本号，例如 17.7.3。") }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 128 * 1024 * 1024 else { throw LCFridaScriptStore.failure("文件超过 128 MiB。") }
        let data = try arm64Slice(Data(contentsOf: url))
        try LCManagedDirectory.ensureWritable(root, inside: LCPath.docPath)
        let value = Version(id: UUID().uuidString, version: version, sha256: LCFridaScriptStore.digest(data), importedAt: Date(), builtin: false)
        let directory = root.appendingPathComponent(value.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: directory.appendingPathComponent("Gadget.dylib"), options: .atomic)
            try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("version.json"), options: .atomic)
        } catch { LCManagedDirectory.cleanup(directory); throw error }
    }
}
