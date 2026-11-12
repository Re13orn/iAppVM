import Foundation

enum LCFridaLogSource: String, CaseIterable {
    case phone, computer, process
    var title: String {
        switch self { case .phone: return "手机自动"; case .computer: return "电脑回传"; case .process: return "进程控制台" }
    }
    var symbol: String {
        switch self { case .phone: return "iphone"; case .computer: return "desktopcomputer"; case .process: return "terminal" }
    }
    var detail: String {
        switch self {
        case .phone: return "只显示手机脚本的 console/send 与已捕获 JS 异常；App、SDK 和网络系统日志请看进程控制台。"
        case .computer: return "电脑配套客户端回传的脚本 console/send/error 与加载状态。普通 Frida CLI 的输出留在电脑终端，不会自动出现在这里。"
        case .process: return "所有启动模式下的 App stdout/stderr 与 Gadget 原始控制台。这里出现监听端口，不表示脚本已经执行。"
        }
    }
    var emptyMessage: String {
        switch self {
        case .phone: return "新版本重新启动目标后才有独立脚本记录。旧会话、未开启记录或保持原格式的打包脚本请查看进程控制台。"
        case .computer: return "使用新生成的电脑连接包运行配套客户端后，可在此查看回传日志。普通 CLI 请看电脑终端。"
        case .process: return "启用控制台记录后重新启动目标，即可查看进程日志。"
        }
    }
    func accepts(_ value: [String: Any]) -> Bool {
        self != .phone || (value["frida"] as? [String:Any])?["automatic"] as? Bool == true
    }
    func exportName(session: String, raw: Bool) -> String {
        let prefix = self == .phone ? "phone-auto" : self == .computer ? "computer-scripts" : "process-console"
        let safe = String(session.prefix(100)).replacingOccurrences(of: "/", with: "_")
        return prefix + "-" + safe + (raw ? "-original" : "") + (self == .computer ? ".jsonl" : ".log")
    }
}

struct LCFridaExecutionStatus {
    let mode: String
    let phone: String
    let computer: String
    static func evaluate(record: [String:Any]?, session: [String:Any]?, client: [String:Any]?, now: Double, phoneStates: [[String:Any]]? = nil) -> Self {
        guard let record, record["state"] as? String == "running", let pid = record["pid"] as? Int, pid > 0 else {
            return Self(mode:"目标未运行",phone:"本次未运行",computer:"本次未运行")
        }
        let started = record["startedAt"] as? Double ?? 0
        guard let session, session["pid"] as? Int == pid, (session["startedAt"] as? Double ?? 0) >= started - 1,
              let frida = session["frida"] as? [String:Any], let automatic = frida["automatic"] as? Bool else {
            return Self(mode:"等待本次启动回执",phone:"本次模式未确认",computer:"本次模式未确认")
        }
        let loaded = (session["plugins"] as? [[String:Any]] ?? []).contains { $0["file"] as? String == "FridaGadget.dylib" && $0["status"] as? String == "loaded" }
        if automatic {
            let count = frida["scriptCount"] as? Int ?? 0
            if loaded, let states=phoneStates {
                let succeeded=states.filter{$0["state"] as? String == "loaded"}.count
                let failed=states.filter{$0["state"] as? String == "error"}.count
                return Self(mode:"手机自动脚本",phone:"\(succeeded) 个已加载 · \(failed) 个失败 · \(max(0,count-succeeded-failed)) 个未确认",computer:"本次未启用电脑连接")
            }
            return Self(mode:"手机自动脚本",phone:loaded ? "Gadget 已加载 · \(count) 个配置脚本，结果见日志" : "手机自动模式 · 等待 Gadget 加载",computer:"本次未启用电脑连接")
        }
        var state = loaded ? "Gadget 监听模式 · 等待电脑回传" : "电脑连接模式 · 等待 Gadget 加载"
        if let client, client["pid"] as? Int == pid {
            let heartbeat = client["heartbeat"] as? Double ?? 0
            let age = now - heartbeat
            if client["connected"] as? Bool == true && heartbeat >= started && age >= -2 && age < 8 {
                if let scripts = client["scripts"] as? [[String:Any]] {
                    let loaded = scripts.filter { $0["state"] as? String == "loaded" }.count
                    let failed = scripts.filter { $0["state"] as? String == "error" }.count
                    state = "电脑已连接 · \(loaded) 个已加载" + (failed > 0 ? " · \(failed) 个失败" : "")
                } else { state = "电脑已连接 · 脚本状态未回传" }
            } else { state = "电脑回传已过期或断开" }
        }
        return Self(mode:"电脑连接脚本",phone:"本次未启用手机自动脚本",computer:state)
    }
}

/// Human-readable computer output; exported JSONL remains unchanged.
enum LCFridaComputerLogFormatter {
    static func text(_ raw: String) -> String {
        raw.components(separatedBy:"\n").map { line -> String in
            guard !line.isEmpty else { return "" }
            guard let data = line.data(using:.utf8), let entry = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                  let message = entry["message"] as? [String:Any] else { return line }
            if message["event"] as? String == "computer-disconnected" { return "[电脑连接] 已断开" }
            if message["event"] as? String == "computer-script-state", let scripts = message["scripts"] as? [[String:Any]] {
                let states = scripts.map { script -> String in
                    let name = script["name"] as? String ?? "未标注脚本"
                    let rawState = script["state"] as? String ?? "unknown"
                    let state = ["loading":"正在加载","loaded":"已加载","error":"失败"][rawState] ?? rawState
                    return name + " · " + state
                }
                return "[电脑脚本状态] " + (states.isEmpty ? "尚未加载" : states.joined(separator:"；"))
            }
            guard let value = message["message"] as? [String:Any] else { return line }
            let script = message["source"] as? String ?? value["script"] as? String ?? "未标注脚本"
            let kind = value["level"] as? String ?? value["type"] as? String ?? "输出"
            let prefix = "[电脑][" + script + "][" + kind + "] "
            if let stack = value["stack"] as? String { return prefix + stack }
            if let description = value["description"] as? String { return prefix + description }
            if let payload = value["payload"] as? String { return prefix + payload }
            if let payload = value["payload"], JSONSerialization.isValidJSONObject([payload]),
               let data = try? JSONSerialization.data(withJSONObject:[payload],options:[.sortedKeys]), let text = String(data:data,encoding:.utf8) {
                return prefix + String(text.dropFirst().dropLast())
            }
            return line
        }.joined(separator:"\n")
    }
}
