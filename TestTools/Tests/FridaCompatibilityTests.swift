import Foundation
import JavaScriptCore

enum LCPath { static let docPath = FileManager.default.temporaryDirectory.appendingPathComponent("iappvm-compat-" + UUID().uuidString) }
@main struct FridaCompatibilityTests {
    static func check(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
        if try !value() { throw NSError(domain: "CompatibilityTest", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    }
    static func main() throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: LCPath.docPath) }
        let raw = "\"use strict\";\nconst icon = '😀'; console.log(ObjC.available); rpc.exports={init(){ return 7; }};"
        let report = try LCFridaScriptCompatibility.inspect(raw)
        try check(report.objc && report.addsObjC(.automatic), "ObjC dependency not detected")
        let prepared = try LCFridaScriptCompatibility.prepare(raw, mode: .automatic)
        try check(prepared.hasPrefix("\"use strict\";"), "strict prologue lost")
        try check(prepared.contains("globalThis.ObjC = bridge"), "bridge not included")
        let context = JSContext()!
        context.evaluateScript("var globalThis=this; var ObjC={available:true}; var rpc={}; var console={log:function(){}};")
        context.evaluateScript(prepared)
        try check(context.exception == nil, "prepared script failed with existing bridge")
        try check(context.evaluateScript("rpc.exports.init()")!.toInt32() == 7, "rpc.exports replaced")
        try check(context.evaluateScript("typeof icon")!.toString() == "string", "top-level scope was wrapped")
        let plain = "// ObjC.available\nconst s='Swift Interceptor require(1)'; const r=/ObjC/; const object={ObjC:1};"
        let plainReport = try LCFridaScriptCompatibility.inspect(plain)
        try check(!plainReport.objc && !plainReport.swift && !plainReport.hooks && !plainReport.modules, "comments or property names detected as dependencies")
        try check(LCFridaScriptCompatibility.prepare(plain, mode: .automatic) == plain, "pure JS rewritten")
        let esm = "#!/agent\nimport ObjC from 'frida-objc-bridge';\nconsole.log(ObjC.available);"
        let normalized = try LCFridaScriptCompatibility.prepare(esm, mode: .automatic)
        try check(normalized.hasPrefix("#!/agent\n\"use strict\";"), "module strictness or hashbang lost")
        try check(!normalized.contains("import ObjC"), "supported import not removed")
        try check(LCFridaScriptCompatibility.inspect(normalized).syntaxError == nil, "normalized import invalid")
        let local = "const ObjC={available:true}; console.log(ObjC.available);"
        try check(LCFridaScriptCompatibility.prepare(local, mode: .automatic) == local, "custom bridge overwritten")
        do { _ = try LCFridaScriptCompatibility.prepare(local, mode: .objc); throw NSError(domain:"expectedConflict",code:1) }
        catch let e as NSError { try check(e.domain == "IOSVMFridaScripts", "ObjC conflict accepted") }
        let modules = "import value from 'some-package'; send(value);"
        try check(LCFridaScriptCompatibility.inspect(modules).modules, "module dependency missing")
        do { _ = try LCFridaScriptCompatibility.prepare(modules, mode: .automatic); throw NSError(domain:"expectedModule",code:1) }
        catch let e as NSError { try check(e.domain == "IOSVMFridaScripts", "unpacked module accepted") }
        try check(LCFridaScriptCompatibility.prepare(modules, mode: .unchanged) == modules, "opt-out changed source")
        let packed = "📦\ncompiled-fixture"
        try check(LCFridaScriptCompatibility.prepare(packed, mode: .automatic) == packed, "compiled bundle corrupted")
        try check(LCFridaScriptCompatibility.inspect("Interceptor.attach(ptr('1'),{}); Swift.available; Module.findExportByName(null,'foo');").hooks, "hook requirement missing")
        try check(LCFridaScriptCompatibility.inspect("const broken = ;").syntaxError != nil, "syntax failure hidden")
        try check(LCFridaScriptCompatibility.inspect("globalThis['ObjC'].available").objc, "global computed ObjC reference missed")
        try check(LCFridaScriptCompatibility.inspect("await ObjC.available").modules, "top-level await accepted as plain script")
        try check(!LCFridaScriptCompatibility.inspect("function F(){return new.target;}").modules, "valid new.target classified as module")
        let customGlobal = "globalThis.ObjC = {}; console.log(ObjC.available);"
        try check(LCFridaScriptCompatibility.prepare(customGlobal,mode:.automatic) == customGlobal, "custom global bridge overwritten")
        let oldMetadata = Data("{\"id\":\"11111111-1111-1111-1111-111111111111\",\"name\":\"legacy\",\"modifiedAt\":0}".utf8)
        try check(JSONDecoder().decode(LCFridaScriptStore.Script.self,from:oldMetadata).effectiveBridgeMode == .automatic, "old metadata not migrated")
        let sideEffect = "globalThis.executedUntrustedSource=true; ObjC.available;"
        try check(LCFridaScriptCompatibility.inspect(sideEffect).objc, "side effect fixture not parsed")
        // Store/launch integration: policy changes rebuild snapshots, originals stay unchanged.
        let script = try LCFridaScriptStore.save(name:"fixture.js", source:raw)
        try check(LCFridaScriptStore.source(script) == raw, "library source changed")
        let folder = LCPath.docPath.appendingPathComponent("plugins")
        try fm.createDirectory(at:folder, withIntermediateDirectories:true)
        let config: [String:Any] = ["interaction":["type":"listen","token":"fixture","port":27042], "runtime":"qjs", "code_signing":"required"]
        try JSONSerialization.data(withJSONObject:config).write(to:folder.appendingPathComponent("FridaGadget.config"))
        var selection = LCFridaScriptStore.Selection(); selection.automatic=true; selection.scripts=[script.id]
        try LCFridaScriptStore.apply(selection,folder:folder)
        let initial = try LCFridaScriptStore.selection(folder:folder)
        let configData = try Data(contentsOf:folder.appendingPathComponent("FridaGadget.config"))
        let json = try JSONSerialization.jsonObject(with:configData) as! [String:Any]
        let dir = folder.appendingPathComponent((json["interaction"] as! [String:Any])["path"] as! String)
        let emitted = try fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).first!
        try check(String(contentsOf:emitted,encoding:.utf8) == LCFridaScriptCompatibility.phoneSource(prepared,id:script.id,name:script.name,count:1), "launch did not use prepared source")
        let generated = try String(contentsOf:emitted,encoding:.utf8)
        try check(generated.contains("startCommandChannel") && generated.contains("Script.evaluate('/phone/"), "real command channel missing from generated script")
        try check(json["code_signing"] as? String == "required", "signing policy changed")
        var hookSelection = initial
        hookSelection.allowGenericHooks = true
        try LCFridaScriptStore.apply(hookSelection,folder:folder)
        let hookConfig = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("FridaGadget.config"))) as! [String:Any]
        try check(hookConfig["code_signing"] as? String == "optional", "generic hook mode did not relax signing policy")
        hookSelection.allowGenericHooks = false
        try LCFridaScriptStore.apply(hookSelection,folder:folder)
        let strictConfig = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("FridaGadget.config"))) as! [String:Any]
        try check(strictConfig["code_signing"] as? String == "required", "generic hook mode did not restore required policy")
        _ = try LCFridaScriptStore.save(id:script.id,name:script.name,source:raw,bridgeMode:.unchanged)
        try LCFridaScriptStore.refreshBeforeLaunch(folder:folder)
        try check(LCFridaScriptStore.selection(folder:folder).fingerprints != initial.fingerprints, "policy change did not rebuild snapshot")
        try check(LCFridaScriptStore.source(script) == raw, "original changed after policy switch")
        let importURL = LCPath.docPath.appendingPathComponent("import-fixture.js")
        try Data("console.log('import-fixture');".utf8).write(to:importURL)
        let importNotes = try LCFridaScriptStore.importFile(importURL)
        try check(importNotes.contains("import-fixture.js") && LCFridaScriptStore.list().contains(where: { $0.name == "import-fixture.js" }), "script import did not persist")
        print("PASS: dependency parser, preservation, module normalization, strictness, RPC, opt-out, snapshot regeneration")
    }
}
