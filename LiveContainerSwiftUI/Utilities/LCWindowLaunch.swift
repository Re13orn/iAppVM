import Foundation

/// Receipt for the authenticated Mac launch helper. Normal UI launches do not create a receipt.
@objc class IOSVMWindowLaunchReporter: NSObject {
    @objc(recordPID:error:bundle:container:)
    static func record(pid: NSNumber?, error: NSError?, bundle: String, container: String) {
        guard let request = UserDefaults.standard.string(forKey: "iosvmWindowRequest"), UUID(uuidString: request) != nil else { return }
        guard UserDefaults.standard.string(forKey: "iosvmWindowApp") == bundle,
              UserDefaults.standard.string(forKey: "iosvmWindowContainer") == container else { return }
        let directory = LCPath.docPath.appendingPathComponent("iOSVM/WindowLaunch")
        var value: [String: Any] = ["request": request, "bundle": bundle, "container": container]
        if let error { value["error"] = error.localizedDescription }
        else if let pid { value["pid"] = pid; value["windowed"] = true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(request + ".json"), options: .atomic)
            // Receipts contain only launch metadata. Bound retained history.
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" }.sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                    ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
            for old in files.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
        } catch { NSLog("iOSVM: could not write window-launch receipt") }
    }
}
