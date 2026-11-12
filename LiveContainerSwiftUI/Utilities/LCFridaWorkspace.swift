import Foundation

/// Recover a detached per-app workspace without overwriting a different selected plugin set.
enum LCFridaWorkspace {
    struct Location {
        let name: String
        let destination: URL
        let source: URL?
        var reuseExisting: Bool { source?.standardizedFileURL.path == destination.standardizedFileURL.path }
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "IOSVMFridaWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    static func locate(base: URL, bundle: String, selected: String?) throws -> Location {
        let fm = FileManager.default
        let canonical = "iOSVM-Frida-" + bundle.replacingOccurrences(of: "/", with: "_")
        func child(_ name: String) throws -> URL {
            guard !name.isEmpty, name != ".", name != "..", name == URL(fileURLWithPath: name).lastPathComponent,
                  !name.contains("\0") else { throw failure("插件目录名无效。") }
            let url = base.appendingPathComponent(name).standardizedFileURL
            let expected = base.resolvingSymlinksInPath().appendingPathComponent(name).standardizedFileURL
            guard url.resolvingSymlinksInPath() == expected else { throw failure("插件目录不能链接到其他位置。") }
            if fm.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw failure("插件目录必须是实际文件夹。") }
            }
            return url
        }
        let selected = selected.flatMap { $0.isEmpty ? nil : $0 }
        let old = try selected.map(child)
        // A previously chosen conflict-free name remains stable on retries.
        if let selected, selected == canonical || selected.hasPrefix(canonical + "-") {
            let destination = try child(selected)
            return Location(name: selected, destination: destination, source: fm.fileExists(atPath: destination.path) ? destination : nil)
        }
        let destination = try child(canonical)
        let source = old.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        if fm.fileExists(atPath: destination.path) {
            if source == nil {
                return Location(name: canonical, destination: destination, source: destination)
            }
            // Keep both plugin sets intact instead of guessing which conflicting files to discard.
            let unique = canonical + "-" + UUID().uuidString
            return Location(name: unique, destination: try child(unique), source: source)
        }
        return Location(name: canonical, destination: destination, source: source)
    }

    /// Returns only real, unreferenced directories created by iAppVM's Gadget
    /// preparation/version switching. Callers must present an explicit confirmation.
    static func unusedFolders(bases: [URL], referenced: Set<String>) throws -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for base in Set(bases.map(\.standardizedFileURL)) {
            guard fm.fileExists(atPath: base.path) else { continue }
            let values = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw failure("调试目录根包含未经允许的链接。")
            }
            let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL
            for item in try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
                let name = item.lastPathComponent
                guard name.hasPrefix("iOSVM-Frida-") || name.hasPrefix(".frida-version-"),
                      !referenced.contains(name) else { continue }
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      item.resolvingSymlinksInPath().standardizedFileURL ==
                        resolvedBase.appendingPathComponent(name).standardizedFileURL else { continue }
                result.append(item)
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}
