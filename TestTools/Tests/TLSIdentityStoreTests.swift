import Foundation

@main struct TLSIdentityStoreTests {
    static func main() throws {
        let container = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let root = container.appendingPathComponent("Library/iOSVM/Network/TLSIdentities", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bad = "00000000-0000-0000-0000-000000000000"
        try Data(repeating: 65, count: Int(IOSVMTLSIdentityMetadataLimit) + 1).write(to: root.appendingPathComponent(bad + ".json"))
        let id = "10000000-0000-0000-0000-000000000000"
        let password = String(repeating: "\u{0001}", count: 8192)
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "state": "exported", "file": id + ".p12", "password": password])
        precondition(data.count > 16384 && data.count <= Int(IOSVMTLSIdentityMetadataLimit))
        try data.write(to: root.appendingPathComponent(id + ".json"))
        let p12 = root.appendingPathComponent(id + ".p12")
        try Data("synthetic file-reader fixture".utf8).write(to: p12)
        let loaded = try LCTLSIdentityStore.load(root: root, inside: container)
        precondition(loaded.entries.count == 1 && loaded.entries[0].available)
        precondition(loaded.entries[0].value["password"] as? String == password)
        precondition(loaded.message?.contains("1 项") == true)
        try FileManager.default.removeItem(at: p12)
        let missing = try LCTLSIdentityStore.load(root: root, inside: container)
        precondition(missing.entries.count == 1 && !missing.entries[0].available)
        try Data().write(to: p12)
        let empty = try LCTLSIdentityStore.load(root: root, inside: container)
        precondition(!empty.entries[0].available)
        print("PASS TLS identity reader: escaped password, shared size bound, corrupt record isolation, missing/empty file status")
    }
}
