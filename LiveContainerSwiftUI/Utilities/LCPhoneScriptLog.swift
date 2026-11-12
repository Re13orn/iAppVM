import Foundation

enum LCPhoneScriptLog {
    static func descriptors(_ session: [String:Any]) -> [[String:Any]] {
        guard let metadata = session["phoneScriptLogs"] as? [String:Any], [1,2].contains(metadata["version"] as? Int ?? 0),
              let scripts = metadata["scripts"] as? [[String:Any]], scripts.count <= 32 else { return [] }
        return scripts.filter { value in
            guard let id=value["id"] as? String, UUID(uuidString:id) != nil else { return false }
            return value["file"] as? String == id + ".jsonl" && value["stateFile"] as? String == id + ".state.json"
        }
    }
    static func supportsCommands(_ session: [String:Any]) -> Bool {
        guard let metadata = session["phoneScriptLogs"] as? [String:Any] else { return false }
        return metadata["version"] as? Int == 2 && metadata["commandProtocol"] as? String == "file-v1"
    }
    static func sendCommand(folder: URL, session: [String:Any], scriptID: String, expression: String) throws -> UUID {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsCommands(session),
              session["pid"] as? Int != nil,
              descriptors(session).contains(where: { $0["id"] as? String == scriptID }) else {
            throw failure("当前会话不支持实时脚本命令，请重新启动新版目标。")
        }
        guard !expression.isEmpty, expression.utf8.count <= 16384, !expression.contains("\0") else {
            throw failure("脚本命令不能为空，且最多 16384 字节。")
        }
        let directory = folder.appendingPathComponent("phone-scripts", isDirectory: true)
        _ = try LCFridaLogBoundary.directory(directory, inside: folder)
        let request = UUID()
        let value: [String:Any] = ["version":1, "id":request.uuidString, "expression":expression]
        let file = directory.appendingPathComponent(scriptID + ".command.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) < 2 {
                throw failure("上一条脚本命令尚未完成，请等待目标回执后再发送。")
            }
        }
        try JSONSerialization.data(withJSONObject:value, options:[.sortedKeys]).write(to:file, options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:file.path)
        return request
    }
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "IOSVMPhoneScripts", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func read(_ file: URL, inside root: URL, limit: Int) throws -> Data {
        let data = try LCFridaLogBoundary.readTail(file, inside: root, limit: limit)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let start = size > limit ? size-limit : 0
        if start > 0, let newline=data.firstIndex(of:10) { return data.suffix(from:data.index(after:newline)) }
        return start > 0 ? Data() : data
    }
    static func entries(folder: URL, session: [String:Any], limit: Int = 262144) throws -> [[String:Any]] {
        let scripts = descriptors(session), pid = session["pid"] as? Int ?? 0
        // Console-only sessions never create phone-scripts. They contribute no
        // phone events and must not block the other sources in the timeline.
        guard !scripts.isEmpty else { return [] }
        let root=folder.appendingPathComponent("phone-scripts")
        _ = try LCFridaLogBoundary.directory(root, inside: folder)
        var result: [[String:Any]]=[]
        for script in scripts {
            let id=script["id"] as! String
            let file=root.appendingPathComponent(id + ".jsonl")
            guard FileManager.default.fileExists(atPath:file.path) else { continue }
            let data = try read(file,inside:folder,limit:max(1,limit/max(1,scripts.count)))
            for line in data.split(separator:10) {
                guard let entry=(try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any],
                      entry["source"] as? String == "phone", entry["scriptID"] as? String == id, entry["pid"] as? Int == pid else { continue }
                result.append(entry)
            }
        }
        return result.sorted { ($0["time"] as? Double ?? 0) < ($1["time"] as? Double ?? 0) }
    }
    static func text(_ entries: [[String:Any]], multiple: Bool) -> String {
        entries.compactMap { entry -> String? in
            guard let value=entry["message"] as? [String:Any] else { return nil }
            let prefix = multiple ? "[" + (entry["script"] as? String ?? "手机脚本") + "] " : ""
            let type=value["type"] as? String
            if type == "command", let payload=value["payload"] as? String { return prefix+"> "+payload }
            if type == "command-result", let payload=value["payload"] as? String { return prefix+"=> "+payload }
            if let stack=value["stack"] as? String { return prefix+stack }
            if let description=value["description"] as? String { return prefix+description }
            if let payload=value["payload"] as? String { return prefix+payload }
            if let payload=value["payload"], let data=try? JSONSerialization.data(withJSONObject:payload,options:[.fragmentsAllowed,.prettyPrinted,.sortedKeys]),let text=String(data:data,encoding:.utf8) { return prefix+text }
            return nil
        }.joined(separator:"\n")
    }
    static func states(folder: URL, session: [String:Any]) -> [[String:Any]] {
        descriptors(session).compactMap { script in
            let file=folder.appendingPathComponent("phone-scripts").appendingPathComponent(script["stateFile"] as! String)
            guard let data=try? read(file,inside:folder,limit:4096),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                  value["source"] as? String == "phone",value["id"] as? String == script["id"] as? String,
                  value["pid"] as? Int == session["pid"] as? Int else { return nil }
            return value
        }
    }
}
