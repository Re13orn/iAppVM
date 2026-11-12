import Foundation
import JavaScriptCore

/// Parse, never evaluate, imported code. Original library files remain byte-for-byte intact.
enum LCFridaScriptCompatibility {
    enum BridgeMode: String, Codable, CaseIterable {
        case automatic, objc, unchanged
        var title: String {
            switch self { case .automatic: return "自动检查"; case .objc: return "补齐 ObjC"; case .unchanged: return "保持原样" }
        }
    }
    struct Range: Decodable { let start: Int; let end: Int }
    struct Report: Decodable {
        var packaged = false
        var syntaxError: String?
        var objc = false
        var swift = false
        var java = false
        var ownObjC = false
        var topObjC = false
        var hooks = false
        var dynamicCode = false
        var legacyAPI = false
        var modules = false
        var objcImports: [Range] = []
        var directiveEnd = 0
        var hashbangEnd = 0
        var moduleStrict: Bool?

        var notes: [String] {
            var notes: [String] = []
            if packaged { return ["已识别 Frida 打包文件，保持完整格式；未检查包内依赖。"] }
            if let syntaxError { return [syntaxError + "。请检查语法、TypeScript 或未完成的打包。"] }
            if !objcImports.isEmpty { notes.append("识别到 ObjC 默认导入，可由内置桥接替代。") }
            else if objc { notes.append(ownObjC ? "脚本含 ObjC 声明，自动模式保留脚本自身的桥接。" : "识别到 ObjC 引用，自动模式会在运行副本中补齐桥接。") }
            if swift { notes.append("识别到 Swift 引用，本版本不自动补齐 Swift 桥接；请随脚本打包。") }
            if java { notes.append("识别到 Java 引用，请确认这是适用于 iOS 的脚本。") }
            if modules { notes.append("存在未打包的 import/export、require 或模块语法，自动运行前需在电脑打包。") }
            if hooks { notes.append("识别到 Interceptor / Stalker，能否运行取决于目标的签名与插桩条件。") }
            if legacyAPI { notes.append("识别到旧版 Module 静态 API，Frida 17 可能需要修改调用方式。") }
            if dynamicCode { notes.append("存在动态代码生成，静态检查无法覆盖其依赖。") }
            if notes.isEmpty { notes.append("未发现需要自动补齐的 ObjC 依赖。") }
            return notes
        }
        func addsObjC(_ mode: BridgeMode) -> Bool {
            guard !packaged, syntaxError == nil, mode != .unchanged else { return false }
            return !objcImports.isEmpty || mode == .objc || (objc && !ownObjC)
        }
    }
    static var resources: URL {
        #if IOSVM_SCRIPT_TESTING
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("TestTools/Frida/ScriptSupport.bundle")
        #else
        return Bundle.main.bundleURL.appendingPathComponent("ScriptSupport.bundle")
        #endif
    }
    static func resource(_ name: String) throws -> String {
        try String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8)
    }
    static func inspect(_ source: String) throws -> Report {
        guard source.utf8.count <= LCFridaScriptStore.maximumBytes else { throw LCFridaScriptStore.failure("脚本超过 8 MiB。") }
        guard let context = JSContext() else { throw LCFridaScriptStore.failure("无法创建脚本检查环境。") }
        context.evaluateScript(try resource("acorn.js"))
        context.evaluateScript(try resource("analyze.js"))
        let result = context.objectForKeyedSubscript("iappvmAnalyze")?.call(withArguments: [source])
        guard context.exception == nil, let json = result?.toString(), let data = json.data(using: .utf8) else {
            throw LCFridaScriptStore.failure("脚本检查未完成，可能包含过深嵌套。请简化或在电脑打包后重试。")
        }
        return try JSONDecoder().decode(Report.self, from: data)
    }
    static func phoneSource(_ source: String, id: UUID, name: String, count: Int) throws -> String {
        // Frida's module bundle format must stay intact; never fall back to mixed stdout as script output.
        if source.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("📦") { return source }
        let key="__iappvmPhone_" + id.uuidString.replacingOccurrences(of:"-",with:"")
        var executable=source
        if let context=JSContext() {
            context.evaluateScript(try resource("acorn.js"))
            context.evaluateScript(try resource("analyze.js"))
            executable=context.objectForKeyedSubscript("iappvmRewritePhoneCalls")?.call(withArguments:[source,key])?.toString() ?? source
        }
        let options: [String:Any] = ["id":id.uuidString,"name":name,"limit":4 * 1024 * 1024 / max(1,count)]
        let metadata = String(data:try JSONSerialization.data(withJSONObject:options,options:[.sortedKeys]),encoding:.utf8)!
        let literal = String(data:try JSONSerialization.data(withJSONObject:[executable],options:[.fragmentsAllowed]),encoding:.utf8)!
        let code = String(literal.dropFirst().dropLast())
        let filename = "/phone/" + id.uuidString + ".js"
        let result = """
        (function () {
        \(try resource("phone-logger.js"))
        const logger = iappvmInstallPhoneLogger(\(metadata));
        globalThis["\(key)"] = logger.bindings;
        try {
          Script.evaluate('\(filename)', \(code));
          logger.wrapInit();
          logger.loaded();
          logger.startCommandChannel(function (expression, commandID) {
            return Script.evaluate('/phone/\(id.uuidString).command.' + commandID + '.js', expression);
          });
        } catch (error) { logger.failure(error); throw error; }
        })();
        """
        guard result.utf8.count <= LCFridaScriptStore.maximumBytes else { throw LCFridaScriptStore.failure("加入独立日志后的运行副本超过 8 MiB。") }
        return result
    }
    static func prepare(_ source: String, mode: BridgeMode) throws -> String {
        // Explicit opt-out also supports syntax newer than the static parser.
        guard mode != .unchanged else { return source }
        let report = try inspect(source)
        if report.packaged {
            guard mode != .objc else { throw LCFridaScriptStore.failure("打包文件不能拼接桥接，请保持原样或在电脑重新打包。") }
            return source
        }
        if let error = report.syntaxError { throw LCFridaScriptStore.failure(error + "。请先修正脚本，或明确选择保持原样。") }
        guard !report.modules else { throw LCFridaScriptStore.failure("脚本仍有未打包的模块依赖，请先在电脑打包，再导入。") }
        guard report.addsObjC(mode) else { return source }
        guard !report.topObjC else { throw LCFridaScriptStore.failure("脚本已声明 ObjC，请使用自动检查或保持原样，避免桥接冲突。") }
        // Preserve directive prologues, including strict mode, and don't wrap user code/rpc.exports.
        let text = NSMutableString(string: source)
        for range in report.objcImports.sorted(by: { $0.start > $1.start }) {
            let original = text.substring(with: NSRange(location: range.start, length: range.end - range.start))
            let blank = original.utf16.map { $0 == 10 || $0 == 13 ? $0 : UInt16(32) }
            text.replaceCharacters(in: NSRange(location: range.start, length: range.end - range.start), with: String(decoding: blank, as: UTF16.self))
        }
        let bridge = try resource("objc.js")
        let bootstrap = """

        ;(function () {
          if (typeof globalThis.ObjC !== 'undefined') return;
          \(bridge)
          globalThis.ObjC = bridge;
        })();

        """
        text.insert(bootstrap, at: report.directiveEnd)
        if report.moduleStrict == true { text.insert("\"use strict\";\n", at: report.hashbangEnd) }
        let result = text as String
        guard result.utf8.count <= LCFridaScriptStore.maximumBytes else { throw LCFridaScriptStore.failure("补齐桥接后的运行副本超过 8 MiB，请缩小脚本。") }
        return result
    }
}
