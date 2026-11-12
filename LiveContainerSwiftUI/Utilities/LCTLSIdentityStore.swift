import Foundation

/// The identity page and its tests share the same bounded file-reading path.
enum LCTLSIdentityStore {
    struct Entry: Identifiable {
        let id: String
        let value: [String: Any]
        let file: URL?
        var available: Bool { file != nil && value["state"] as? String == "exported" }
    }
    struct Report {
        var entries: [Entry] = []
        var message: String?
    }
    static func load(root: URL, inside container: URL) throws -> Report {
        _ = try LCFridaLogBoundary.directory(root, inside: container)
        var result = Report()
        let status = root.deletingLastPathComponent().appendingPathComponent("status.json")
        if let data = try? LCFridaLogBoundary.readData(status, inside: container, maximumBytes: 65536),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = value["tlsIdentityError"] as? String, !error.isEmpty { result.message = error }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var unreadable = 0
        for meta in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(200) {
            if result.entries.count >= 20 { break }
            do {
                let data = try LCFridaLogBoundary.readData(meta, inside: container, maximumBytes: Int(IOSVMTLSIdentityMetadataLimit))
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = value["id"] as? String, UUID(uuidString: id) != nil, meta.lastPathComponent == id + ".json" else { unreadable += 1; continue }
                var file: URL?
                if value["state"] as? String == "exported", value["file"] as? String == id + ".p12" {
                    let candidate = root.appendingPathComponent(id + ".p12")
                    if let data = try? LCFridaLogBoundary.readData(candidate, inside: container, maximumBytes: 8 * 1024 * 1024), !data.isEmpty { file = candidate }
                }
                result.entries.append(Entry(id: id, value: value, file: file))
            } catch { unreadable += 1 }
        }
        if unreadable > 0 { result.message = [result.message, "\(unreadable) 项身份记录无法读取，其余记录仍展示。"].compactMap { $0 }.joined(separator: "\n") }
        return result
    }
}
