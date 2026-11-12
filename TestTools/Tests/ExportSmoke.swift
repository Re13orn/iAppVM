import Foundation

@main struct ExportSmoke {
    static func main() throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("iosvm-export-test-" + UUID().uuidString)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("source")
        let destination = workspace.appendingPathComponent("snapshot")
        try fm.createDirectory(at: source.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let payload = Data("probeLoaded\n测试\n".utf8)
        try payload.write(to: source.appendingPathComponent("Documents/session.jsonl"))
        let outside = workspace.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try fm.createSymbolicLink(at: source.appendingPathComponent("external"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: source.appendingPathComponent("loop"), withDestinationURL: source)
        try LCContainerExport.snapshot(source: source, destination: destination)
        guard try Data(contentsOf: destination.appendingPathComponent("Documents/session.jsonl")) == payload,
              !fm.fileExists(atPath: destination.appendingPathComponent("external").path),
              !fm.fileExists(atPath: destination.appendingPathComponent("loop").path) else {
            fatalError("Snapshot did not preserve files or exclude links")
        }
        do {
            try LCContainerExport.snapshot(source: source, destination: source.appendingPathComponent("recursive"))
            fatalError("Nested destination was accepted")
        } catch let error as NSError {
            guard error.domain == "iOSVMExport" else { throw error }
        }
        let archive = try LCContainerExport.archive(source: source)
        defer { try? fm.removeItem(at: archive.deletingLastPathComponent()) }
        let data = try Data(contentsOf: archive)
        guard data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { fatalError("Not a ZIP archive") }
        let unpacked = workspace.appendingPathComponent("unpacked")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, unpacked.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { fatalError("Cannot extract ZIP") }
        guard let enumerator = fm.enumerator(at: unpacked, includingPropertiesForKeys: nil) else { fatalError("No ZIP contents") }
        let files = enumerator.allObjects.compactMap { $0 as? URL }
        guard let session = files.first(where: { $0.lastPathComponent == "session.jsonl" }),
              try Data(contentsOf: session) == payload,
              !files.contains(where: { ["external", "loop"].contains($0.lastPathComponent) }) else {
            fatalError("ZIP content mismatch")
        }
        print("PASS: snapshot, link exclusion, recursion guard, ZIP round trip")
    }
}
