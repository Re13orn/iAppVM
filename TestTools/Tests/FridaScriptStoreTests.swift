import Foundation

enum LCPath { static let docPath = FileManager.default.temporaryDirectory.appendingPathComponent("iosvm-script-tests-" + UUID().uuidString) }
@main struct FridaScriptStoreTests {
    static func require(_ ok: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !ok() { throw NSError(domain: "ScriptTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        let fm = FileManager.default, root = LCPath.docPath
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = try LCFridaScriptStore.save(name: "same.js", source: "const shared = 1; rpc.exports = {init() { console.log('one'); }};")
        let b = try LCFridaScriptStore.save(name: "same.js", source: "const shared = 2; send('two');")
        try require(a.id != b.id && LCFridaScriptStore.list().count == 2, "duplicate filenames collided")
        let folder = root.appendingPathComponent("Plugins")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let config = folder.appendingPathComponent("FridaGadget.config")
        let original: [String: Any] = ["interaction": ["type": "listen", "address": "127.0.0.1", "port": 27042, "token": "original-token", "on_load": "wait"], "runtime": "qjs", "code_signing": "required"]
        try JSONSerialization.data(withJSONObject: original).write(to: config)
        let other = root.appendingPathComponent("OtherAppPlugins")
        try fm.createDirectory(at: other, withIntermediateDirectories: false)
        let untouched = try Data(contentsOf: config)
        try untouched.write(to: other.appendingPathComponent("FridaGadget.config"))
        var selected = LCFridaScriptStore.Selection(); selected.owner = "AppA.app"; selected.automatic = true; selected.scripts = [a.id,b.id]; selected.computerScripts = [b.id]
        try LCFridaScriptStore.apply(selected, folder: folder)
        try require(Data(contentsOf: other.appendingPathComponent("FridaGadget.config")) == untouched, "one app changed another app's settings")
        do { try LCFridaScriptStore.refreshBeforeLaunch(folder: folder, owner: "AppB.app"); throw NSError(domain:"acceptedOtherOwner",code:1) }
        catch let e as NSError { try require(e.domain == "IOSVMFridaScripts", "another app accepted this startup configuration") }
        let saved = try LCFridaScriptStore.selection(folder: folder)
        try require(saved.computerScripts == [b.id] && saved.scripts == [a.id,b.id], "phone/computer selections mixed")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
        let interaction = json["interaction"] as! [String: Any]
        try require(interaction["type"] as? String == "script-directory", "auto mode not installed")
        let generation = folder.appendingPathComponent(interaction["path"] as! String)
        let files = try fm.contentsOfDirectory(at: generation, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        try require(files.count == 2, "scripts were not separate")
        try require(String(contentsOf: files[0], encoding: .utf8).contains("Script.evaluate") && LCFridaScriptStore.source(a).hasPrefix("const shared"), "script source was rewritten")
        try require(saved.listen["token"] == "original-token" && saved.listen["on_load"] == "wait", "listen identity was lost")
        let unrelated = folder.appendingPathComponent("iOSVMScripts/" + UUID().uuidString)
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: unrelated.appendingPathComponent("resource.txt"))
        _ = try LCFridaScriptStore.save(id: a.id, name: "renamed.js", source: "send('updated');")
        try LCFridaScriptStore.refreshBeforeLaunch(folder: folder)
        try require(fm.fileExists(atPath: unrelated.appendingPathComponent("resource.txt").path), "refresh deleted an unrelated resource")
        let refreshed = try LCFridaScriptStore.selection(folder: folder)
        try require(refreshed.fingerprints != saved.fingerprints, "edit did not refresh startup snapshot")
        try LCFridaScriptStore.remove(b)
        let prior = try Data(contentsOf: config)
        do { try LCFridaScriptStore.refreshBeforeLaunch(folder: folder); throw NSError(domain:"acceptedMissing",code:1) }
        catch let e as NSError { try require(e.domain == "IOSVMFridaScripts", "missing script unexpectedly accepted") }
        try require(Data(contentsOf: config) == prior, "failed refresh changed live configuration")
        var disabled = refreshed; disabled.automatic = false
        disabled.computerScripts = [a.id]
        try LCFridaScriptStore.apply(disabled, folder: folder)
        try require(LCFridaScriptStore.selection(folder:folder).scripts == refreshed.scripts && LCFridaScriptStore.selection(folder:folder).computerScripts == [a.id], "computer save overwrote phone scripts")
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
        let listen = restored["interaction"] as! [String: Any]
        try require(listen["type"] as? String == "listen" && listen["token"] as? String == "original-token" && listen["on_load"] as? String == "wait", "computer mode did not restore identity")
        let real = try Data(contentsOf: URL(fileURLWithPath: "Resources/iOSVMFrida.bundle/FridaGadget.dylib"))
        try require(LCFridaVersions.arm64Slice(real) == real, "bundled arm64 iOS dylib rejected")
        var fat = Data(repeating: 0, count: 4096)
        let fatWords: [UInt32] = [0xcafebabe,1,0x0100000c,0,4096,UInt32(real.count),12]
        for (index, word) in fatWords.enumerated() { for byte in 0..<4 { fat[index*4+byte] = UInt8(truncatingIfNeeded: word >> ((3-byte)*8)) } }
        fat.append(real)
        try require(LCFridaVersions.arm64Slice(fat) == real, "universal arm64 extraction failed")
        var macho = Data(real.prefix(32)); macho[12] = 2
        do { _ = try LCFridaVersions.arm64Slice(macho); throw NSError(domain:"acceptedExecutable",code:1) }
        catch let e as NSError { try require(e.domain == "IOSVMFridaScripts", "executable accepted as Gadget") }
        macho[12] = 6
        do { _ = try LCFridaVersions.arm64Slice(macho); throw NSError(domain:"acceptedTruncated",code:1) }
        catch let e as NSError { try require(e.domain == "IOSVMFridaScripts", "truncated dylib accepted") }
        let linked = root.appendingPathComponent("Linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: folder)
        do { try LCFridaScriptStore.apply(disabled, folder: linked); throw NSError(domain:"acceptedLink",code:1) }
        catch let e as NSError { try require(e.domain == "IOSVMFridaScripts", "symlink target accepted") }
        print("PASS: script identities; isolated contexts; source preservation; auto refresh; deleted-script failure preserves config; listen restoration; Mach-O validation; symlink rejection")
    }
}
