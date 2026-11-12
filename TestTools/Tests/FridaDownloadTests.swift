import Foundation

enum LCPath { static let docPath = FileManager.default.temporaryDirectory.appendingPathComponent("iosvm-download-tests-" + UUID().uuidString) }
@main struct FridaDownloadTests {
    static func main() async throws {
        defer { try? FileManager.default.removeItem(at: LCPath.docPath) }
        for (version, path) in [("17.7.3","build/frida/frida-gadget-17.7.3-ios-universal.dylib.xz"),
                                ("17.0.0","build/debug-workbench/gadget17.dylib.xz"),
                                ("16.7.19","build/debug-workbench/gadget16.dylib.xz")] {
            let source = try Data(contentsOf: URL(fileURLWithPath:path))
            precondition(LCFridaScriptStore.digest(source) == LCFridaDownload.pinned[version])
            var error: NSError?
            guard let data = iosvmDecodeGadgetXZ(source, &error) else { throw error! }
            _ = try LCFridaVersions.arm64Slice(data)
            precondition(iosvmDecodeGadgetXZ(source.prefix(source.count/2), &error) == nil)
            print("PASS XZ + iOS arm64 validation and truncation rejection:",version)
        }
        var error: NSError?
        precondition(iosvmDecodeGadgetXZ(Data("not compressed".utf8), &error) == nil)
        let bomb = try Data(contentsOf: URL(fileURLWithPath:"build/debug-workbench/xz-limit.xz"))
        precondition(iosvmDecodeGadgetXZ(bomb, &error) == nil)
        precondition(!LCFridaDownload.valid("../17.0.0") && LCFridaDownload.valid("16.7.19"))
        print("PASS invalid stream, decompressed size bound, version path validation")
        let cancelled = Task { try await LCFridaDownload.fetch(URL(string:"https://api.github.com/repos/frida/frida/releases")!, limit:128) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancelled request succeeded") }
        catch is CancellationError { print("PASS cancellation before request") }
        if CommandLine.arguments.contains("--network") {
            let versions = try await LCFridaDownload.recent()
            precondition(!versions.isEmpty)
            try await LCFridaDownload.download("16.7.19") { _,_ in }
            let imported = try LCFridaVersions.versions().first { $0.version == "16.7.19" }!
            _ = try LCFridaVersions.library(imported)
            print("PASS GitHub recent list + historical pinned download + decode + version-store import")
        }
    }
}
