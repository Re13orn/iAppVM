import Foundation

/// Signing remains in the management process; guest windows receive signed code, never the key.
enum IOSVMDeviceSigning {
    @MainActor private static var active = Set<String>()

    static var configured: Bool {
        LCSharedUtils.certificatePassword() != nil && LCUtils.certificateData() != nil
    }

    @MainActor private static var provisioningActive = false

    /// One-time USB provisioning stays outside Documents and is removed after consumption.
    @MainActor static func consumeProvisioning() async throws {
        guard !provisioningActive else { return }
        provisioningActive = true
        defer { provisioningActive = false }
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iOSVM-signing-setup.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var setupRemoved = false
        var result: [String: Any] = ["state": "error", "message": "lc.signing.setupIncomplete".loc]
        defer {
            if !setupRemoved { try? FileManager.default.removeItem(at: url) }
            if let status = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                try? status.write(to: url.deletingLastPathComponent().appendingPathComponent("iOSVM-signing-status.json"), options: [.atomic, .completeFileProtection])
            }
        }
        let data = try Data(contentsOf: url)
        guard data.count < 1_048_576,
              let setup = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              setup["host"] as? String == Bundle.main.bundleIdentifier,
              let requestID = setup["id"] as? String, UUID(uuidString: requestID) != nil,
              let certificate = setup["certificate"] as? Data, let password = setup["password"] as? String else {
            throw "lc.signing.setupInvalid".loc
        }
        result["id"] = requestID
        if let error = LCUtils.validateSigningKey(certificate, password: password) { result["message"] = error; throw error }
        if let error = LCSharedUtils.storeDeviceSigningCertificate(certificate, password: password) { result["message"] = error; throw error }
        // Remove the transfer file before awaiting the signer; a later configuration must not
        // be removed by this request's deferred cleanup.
        try FileManager.default.removeItem(at: url)
        setupRemoved = true
        if setup["verifySigning"] as? Bool == true {
            do { try await verifyLocalSigning() }
            catch {
                result["message"] = "签名身份已保存，但实际签名自检失败：" + error.localizedDescription
                throw error
            }
        }
        result = ["state": "ready", "storage": "device-keychain", "host": Bundle.main.bundleIdentifier ?? "", "id": requestID,
                  "signingProbe": setup["verifySigning"] as? Bool == true ? "passed" : "not-requested"]
    }

    /// Signs a disposable copy of our own probe. It is never loaded and touches no Guest.
    /// A successful signature is a signer check, not proof of Guest execution.
    @MainActor private static func verifyLocalSigning() async throws {
        guard let source = Bundle.main.url(forResource: "iOSVMProbe", withExtension: "bundle")?.appendingPathComponent("iOSVMProbe.dylib"),
              FileManager.default.fileExists(atPath: source.path) else { throw "安装包缺少签名自检资源。" }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("signing-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("iOSVMProbe.dylib")
        try FileManager.default.copyItem(at: source, to: destination)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = LCUtils.signFilesWithZSign(with: [destination]) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? NSError(domain: "iAppVM.SigningProbe", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "手机签名自检失败。"])) }
            }
        }
    }

    @MainActor static func sign(_ app: LCAppInfo) async throws {
        guard configured else { throw "lc.signing.importP12First".loc }
        if let error = LCUtils.validateSigningKey(LCUtils.certificateData()!, password: LCSharedUtils.certificatePassword()!) { throw error }
        guard !app.is32bit, !app.isShared else { throw "lc.signing.arm64LocalOnly".loc }
        let name = app.relativeBundlePath!
        guard active.insert(name).inserted else { throw "lc.signing.inProgress".loc }
        defer { active.remove(name) }
        let queue = LCPath.docPath.appendingPathComponent("iOSVM/SigningRequests")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        let url = queue.appendingPathComponent(name + ".json")
        // A new generation invalidates any Mac result still being prepared.
        let generation = UUID().uuidString
        var request: [String: Any] = ["version": 1, "id": generation, "guest": name,
            "bundleID": app.bundleIdentifier()!, "tweakFolder": app.tweakFolder ?? "", "shared": false,
            "signer": "device", "state": "device-signing"]
        func saveRequest() throws {
            try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) .write(to: url, options: .atomic)
        }
        app.info()["IOSVMSigningGeneration"] = generation
        app.info()["IOSVMNeedsExternalSigning"] = true
        app.info()["IOSVMDeviceSigned"] = false
        app.info()["IOSVMExternallySigned"] = false
        app.dontSign = false
        app.save()
        try saveRequest()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                app.patchExecAndSignIfNeed(completionHandler: { success, error in
                    if success { continuation.resume() }
                    else { continuation.resume(throwing: (error ?? "lc.signing.failed".loc)) }
                }, progressHandler: { _ in }, forceSign: true)
            }
            if let folder = LCFridaSetup.folder(for: app) {
                try await LCUtils.signTweaks(tweakFolderUrl: folder, force: true)
            }
            try await LCUtils.signTweaks(tweakFolderUrl: LCPath.tweakPath, force: true)
            app.info()["IOSVMDeviceSigned"] = true
            app.info()["IOSVMNeedsExternalSigning"] = false
            app.isJITNeeded = false
            app.save()
            request["state"] = "ready"
            try saveRequest()
        } catch {
            // Partial output must stay unlaunchable until an explicit retry succeeds.
            app.info()["IOSVMDeviceSigned"] = false
            app.info()["IOSVMNeedsExternalSigning"] = true
            app.save()
            request["state"] = "device-error"
            request["error"] = error.localizedDescription
            try? saveRequest()
            throw error
        }
    }
}
