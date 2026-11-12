import Foundation

enum LCContainerExport {
    /// Copy only regular files and directories, without following links out of the container.
    static func snapshot(source: URL, destination: URL) throws {
        let fm = FileManager.default
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard destination != source,
              !destination.path.hasPrefix(source.path + "/") else {
            throw NSError(domain: "iOSVMExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Export destination must be outside the source directory."])
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        try copyContents(source: source, destination: destination)
    }

    private static func copyContents(source: URL, destination: URL) throws {
        let fm = FileManager.default
        for entry in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let attributes = try fm.attributesOfItem(atPath: entry.path)
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
                try copyContents(source: entry, destination: target)
            case .typeRegular:
                try fm.copyItem(at: entry, to: target)
            default:
                // Symlinks, sockets and other special files are excluded.
                continue
            }
        }
    }

    static func archive(source: URL) throws -> URL {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("iOSVM-export-" + UUID().uuidString)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        do {
            let snapshotURL = workspace.appendingPathComponent("Container")
            try snapshot(source: source, destination: snapshotURL)
            var coordinationError: NSError?
            var result: Result<URL, Error>?
            NSFileCoordinator().coordinate(readingItemAt: snapshotURL, options: .forUploading, error: &coordinationError) { uploadURL in
                result = Result {
                    let output = workspace.appendingPathComponent("Container.zip")
                    try fm.copyItem(at: uploadURL, to: output)
                    return output
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else {
                throw NSError(domain: "iOSVMExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "The export coordinator did not produce an archive."])
            }
            let output = try result.get()
            LCManagedDirectory.cleanup(snapshotURL)
            return output
        } catch {
            try? fm.removeItem(at: workspace)
            throw error
        }
    }
}
