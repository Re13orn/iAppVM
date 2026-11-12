import Foundation

/// Only official frida/frida release assets are accepted. Downloading never changes an App's selection.
enum LCFridaDownload {
    struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    struct Asset: Decodable {
        let name: String
        let size: Int
        let browser_download_url: URL
        let digest: String?
    }
    static let presets = ["17.7.3", "17.0.0", "16.7.19"]
    static let pinned = [
        "17.7.3": "c95d689d93e91228ca69327620d2f2074801c96f39cb80c5473392e8d57ab456",
        "17.0.0": "14ebf9c40c34292008f367c7c30a35c2cd5db589ad9837eff486a52a93c19762",
        "16.7.19": "8ad9bc514778adf351a8b3c00311a67419064b6554ea866d959917317566c3d1"
    ]
    static func valid(_ version: String) -> Bool {
        version.utf8.count <= 32 && version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil
    }
    static func page(_ version: String) -> URL {
        URL(string: "https://github.com/frida/frida/releases/tag/" + version)!
    }
    static func assetURL(_ version: String) -> URL {
        URL(string: "https://github.com/frida/frida/releases/download/\(version)/frida-gadget-\(version)-ios-universal.dylib.xz")!
    }
    static func fetch(_ url: URL, limit: Int, progress: @escaping @Sendable (Int, Int) async -> Void = { _,_ in }) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("iOSVM-Gadget-Versions", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let observer = LCFridaDownloadProgress(limit: limit, progress: progress)
        let (file, response) = try await session.download(for: request, delegate: observer)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LCFridaScriptStore.failure(code == 403 || code == 429 ? "GitHub 请求受限，请稍后重试。" : "GitHub 下载失败（HTTP \(code)）。请检查版本是否存在与网络连接。")
        }
        guard response.url?.scheme == "https", response.expectedContentLength <= Int64(limit),
              try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= limit else {
            throw LCFridaScriptStore.failure("下载响应无效或超过大小限制。")
        }
        try Task.checkCancellation()
        let data = try Data(contentsOf: file)
        await progress(data.count, max(0, Int(response.expectedContentLength)))
        return data
    }
    static func recent() async throws -> [String] {
        let data = try await fetch(URL(string: "https://api.github.com/repos/frida/frida/releases?per_page=5")!, limit: 8 * 1024 * 1024)
        return try JSONDecoder().decode([Release].self, from: data).filter { release in
            !release.draft && !release.prerelease && valid(release.tag_name) && release.assets.contains { $0.name == "frida-gadget-\(release.tag_name)-ios-universal.dylib.xz" }
        }.map(\.tag_name)
    }
    static func download(_ version: String, progress: @escaping @Sendable (Int, Int) async -> Void) async throws {
        guard valid(version) else { throw LCFridaScriptStore.failure("请输入版本号，例如 17.7.3。") }
        let metadata = try await fetch(URL(string: "https://api.github.com/repos/frida/frida/releases/tags/" + version)!, limit: 2 * 1024 * 1024)
        let release = try JSONDecoder().decode(Release.self, from: metadata)
        let expected = assetURL(version)
        guard release.tag_name == version, !release.draft, !release.prerelease,
              let asset = release.assets.first(where: { $0.name == expected.lastPathComponent }),
              asset.browser_download_url == expected, asset.size > 0, asset.size <= 32 * 1024 * 1024 else {
            throw LCFridaScriptStore.failure("此官方版本没有可用的 iOS Universal Gadget。")
        }
        let hash = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil } ?? pinned[version]
        guard let hash, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw LCFridaScriptStore.failure("此历史版本未提供 SHA-256，且没有预置校验值。请使用手动导入。")
        }
        let compressed = try await fetch(expected, limit: 32 * 1024 * 1024, progress: progress)
        guard compressed.count == asset.size, LCFridaScriptStore.digest(compressed) == hash else {
            throw LCFridaScriptStore.failure("下载文件大小或 SHA-256 校验失败，请重试。")
        }
        try Task.checkCancellation()
        var error: NSError?
        guard let decoded = iosvmDecodeGadgetXZ(compressed, &error) else { throw error ?? LCFridaScriptStore.failure("XZ 解压失败。") }
        _ = try LCFridaVersions.arm64Slice(decoded)
        try Task.checkCancellation()
        let workspace = try LCManagedDirectory.temporaryWorkspace()
        defer { LCManagedDirectory.cleanup(workspace) }
        let file = workspace.appendingPathComponent("Gadget.dylib")
        try decoded.write(to: file, options: .atomic)
        try LCFridaVersions.importFile(file, version: version)
    }
}

private final class LCFridaDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int
    let progress: @Sendable (Int, Int) async -> Void
    // URLSession serializes delegate callbacks; only this callback accesses reported.
    private var reported: Int64 = 0
    init(limit: Int, progress: @escaping @Sendable (Int, Int) async -> Void) { self.limit = limit; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else { downloadTask.cancel(); return }
        if totalBytesWritten - reported >= 262144 {
            reported = totalBytesWritten
            Task { await progress(Int(totalBytesWritten), max(0, Int(totalBytesExpectedToWrite))) }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
