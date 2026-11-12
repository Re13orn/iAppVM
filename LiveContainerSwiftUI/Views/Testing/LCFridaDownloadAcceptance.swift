#if IOSVM_TESTING
import Foundation

enum LCFridaDownloadAcceptance {
    @MainActor static func run() async {
        let output = LCPath.docPath.appendingPathComponent("iOSVMUITests/gadget-download.json")
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        var report: [String: Any] = ["state":"running"]
        func write() { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output,options:.atomic) }
        write()
        do {
            let existing = Set(try LCFridaVersions.versions().map(\.id))
            let local = LCPath.docPath.appendingPathComponent("Inbox/DownloadCheck.xz")
            if FileManager.default.fileExists(atPath:local.path) {
                var error: NSError?
                guard let decoded = iosvmDecodeGadgetXZ(try Data(contentsOf:local), &error) else { throw error! }
                _ = try LCFridaVersions.arm64Slice(decoded)
            }
            report["localXZ"] = "passed"; report["stage"] = "recent"; write()
            let recent = try await LCFridaDownload.recent()
            report["stage"] = "download"; write()
            try await LCFridaDownload.download("16.7.19") { _,_ in }
            let created = try LCFridaVersions.versions().filter { !existing.contains($0.id) }
            for version in created {
                _ = try LCFridaVersions.library(version)
                guard version.version == "16.7.19", UUID(uuidString:version.id) != nil else { throw "Unexpected test version" }
                try FileManager.default.removeItem(at: LCFridaVersions.root.appendingPathComponent(version.id))
            }
            report = ["state":"passed","version":"16.7.19","recent":recent,"createdAndCleaned":created.map(\.id)]
        } catch { report = ["state":"failed","error":error.localizedDescription] }
        write()
    }
}
#endif
