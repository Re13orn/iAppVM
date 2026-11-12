// Exercise the production state machine with deterministic signer failures.
import Foundation
extension String: @retroactive Error { var loc: String { self } }
func check(_ value: Bool) { precondition(value) }
enum LCPath {
    static let docPath = FileManager.default.temporaryDirectory.appendingPathComponent("iosvm-device-sign-" + UUID().uuidString)
    static let tweakPath = docPath.appendingPathComponent("Tweaks")
}
enum LCSharedUtils {
    static func certificatePassword() -> String? { "fixture" }
    static func storeDeviceSigningCertificate(_ data: Data, password: String) -> String? { nil }
}
enum LCUtils {
    static func signFilesWithZSign(with urls: [URL], completionHandler: (Bool, NSError?) -> Void) -> Progress? {
        completionHandler(true, nil); return nil
    }
    static var failPlugin = false
    static func certificateData() -> Data? { Data("fixture".utf8) }
    static func validateSigningKey(_ data: Data, password: String) -> String? { nil }
    static func signTweaks(tweakFolderUrl: URL, force: Bool) async throws {
        if failPlugin { throw "injected plugin signing failure" }
    }
}
enum LCFridaSetup {
    static func folder(for app: LCAppInfo) -> URL? { LCPath.tweakPath.appendingPathComponent("fixture") }
}
final class LCAppInfo {
    var is32bit = false
    var isShared = false
    var dontSign = true
    var isJITNeeded = true
    var relativeBundlePath: String! = "fixture.app"
    var tweakFolder: String? = "fixture"
    var failApp = false
    let dictionary = NSMutableDictionary()
    func info() -> NSMutableDictionary { dictionary }
    func bundleIdentifier() -> String! { "dev.iosvm.fixture" }
    func save() {}
    func patchExecAndSignIfNeed(completionHandler: (Bool, String?) -> Void, progressHandler: (Progress?) -> Void, forceSign: Bool) {
        precondition(!dontSign && forceSign)
        completionHandler(!failApp, failApp ? "injected app signing failure" : nil)
    }
}
@main struct DeviceSigningSmoke {
    @MainActor static func main() async throws {
        defer { try? FileManager.default.removeItem(at: LCPath.docPath) }
        let app = LCAppInfo()
        let url = LCPath.docPath.appendingPathComponent("iOSVM/SigningRequests/fixture.app.json")
        func state() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }
        try await IOSVMDeviceSigning.sign(app)
        check(try state()["state"] as? String == "ready")
        precondition(app.info()["IOSVMDeviceSigned"] as? Bool == true && !app.isJITNeeded)
        let first = app.info()["IOSVMSigningGeneration"] as! String
        app.failApp = true
        do { try await IOSVMDeviceSigning.sign(app); fatalError("Expected app failure") } catch {}
        check(try state()["state"] as? String == "device-error")
        precondition(app.info()["IOSVMNeedsExternalSigning"] as? Bool == true)
        precondition(app.info()["IOSVMDeviceSigned"] as? Bool == false)
        app.failApp = false
        LCUtils.failPlugin = true
        do { try await IOSVMDeviceSigning.sign(app); fatalError("Expected plugin failure") } catch {}
        check(try state()["state"] as? String == "device-error")
        LCUtils.failPlugin = false
        try await IOSVMDeviceSigning.sign(app)
        check(try state()["state"] as? String == "ready")
        precondition(app.info()["IOSVMSigningGeneration"] as? String != first)
        precondition(app.info()["IOSVMNeedsExternalSigning"] as? Bool == false)
        app.isShared = true
        do { try await IOSVMDeviceSigning.sign(app); fatalError("Expected shared rejection") } catch {}
        print("Device signing state machine: success, app/plugin failure, retry, generation replacement and shared rejection passed")
    }
}
