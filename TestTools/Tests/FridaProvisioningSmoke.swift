// Runs the real provisioning utility with a temporary filesystem and no signing key.
import Foundation

extension String: @retroactive Error {}
func check(_ value: Bool) { precondition(value) }

enum LCPath {
    static let docPath = FileManager.default.temporaryDirectory.appendingPathComponent("iosvm-frida-test-" + UUID().uuidString)
    static let tweakPath = docPath.appendingPathComponent("Tweaks")
    static let lcGroupTweakPath = docPath.appendingPathComponent("SharedTweaks")
}
enum LCUtils {
    static func signTweaks(tweakFolderUrl: URL, force: Bool) async throws {}
}
final class LCAppInfo {
    var is32bit = false
    var isShared = false
    var dontInjectTweakLoader = false
    var dontLoadTweakLoader = true
    var tweakFolder: String?
    var relativeBundlePath: String!
    let dictionary = NSMutableDictionary()
    init(_ name: String) { relativeBundlePath = name + ".app" }
    func info() -> NSMutableDictionary { dictionary }
    func bundleIdentifier() -> String! { "dev.test." + relativeBundlePath }
    func save() {}
}

@main struct FridaProvisioningSmoke {
    static func main() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: LCPath.tweakPath, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: LCPath.docPath) }
        let original = LCPath.tweakPath.appendingPathComponent("Existing")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        let plugin = Data("fixture dylib".utf8)
        try plugin.write(to: original.appendingPathComponent("Prior.dylib"))
        let app = LCAppInfo("first")
        app.tweakFolder = "Existing"
        try await LCFridaSetup.prepare(app)
        let folder = LCFridaSetup.folder(for: app)!
        check(folder != original)
        check(try Data(contentsOf: folder.appendingPathComponent("Prior.dylib")) == plugin)
        check(try Data(contentsOf: original.appendingPathComponent("Prior.dylib")) == plugin)
        check(!fm.fileExists(atPath: original.appendingPathComponent(LCFridaSetup.library).path))
        check(LCFridaSetup.enabled(app) && !app.dontLoadTweakLoader)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("iOSVMPlugins.json"))) as! [String: Any]
        let rules = manifest["plugins"] as! [[String: Any]]
        check(rules.contains { $0["file"] as? String == "Prior.dylib" && $0["requires"] as? [String] == [LCFridaSetup.library] })
        let config = try LCFridaSetup.config(app)
        let interaction = config["interaction"] as! [String: Any]
        check(interaction["on_load"] as? String == "resume")
        let token = interaction["token"] as! String
        check(token.count == 48)
        let permissions = try fm.attributesOfItem(atPath: folder.appendingPathComponent(LCFridaSetup.configuration).path)[.posixPermissions] as! NSNumber
        check(permissions.intValue == 0o600)
        try await LCFridaSetup.prepare(app)
        check(((try LCFridaSetup.config(app))["interaction"] as! [String: Any])["token"] as! String == token)
        try LCFridaSetup.setWait(true, app: app)
        check(((try LCFridaSetup.config(app))["interaction"] as! [String: Any])["on_load"] as! String == "wait")
        let other = LCAppInfo("second")
        try await LCFridaSetup.prepare(other)
        check(((try LCFridaSetup.config(other))["interaction"] as! [String: Any])["token"] as! String != token)
        check(((try LCFridaSetup.config(other))["interaction"] as! [String: Any])["port"] as! Int != interaction["port"] as! Int)
        try LCFridaSetup.requestSigning(app)
        let queue = LCPath.docPath.appendingPathComponent("iOSVM/SigningRequests/first.app.json")
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: queue)) as! [String: Any]
        check(request["state"] as? String == "pending")
        check(request["id"] as? String == app.info()["IOSVMSigningGeneration"] as? String)
        check(!(try String(contentsOf: queue, encoding: .utf8)).contains(token))
        let bad = LCAppInfo("bad")
        bad.tweakFolder = "Existing"
        try Data("not JSON".utf8).write(to: original.appendingPathComponent("iOSVMPlugins.json"))
        do { try await LCFridaSetup.prepare(bad); fatalError("Malformed manifest was accepted") } catch {}
        check(bad.tweakFolder == "Existing")
        check(!fm.fileExists(atPath: LCPath.tweakPath.appendingPathComponent("iOSVM-Frida-bad.app").path))
        check(try fm.contentsOfDirectory(atPath: LCPath.tweakPath.path).allSatisfy { !$0.hasPrefix(".frida-setup-") })
        print("PASS: Gadget provisioning, plugin preservation, token isolation/permissions, repeat setup, wait mode, signing queue, failure rollback")
    }
}
