import Foundation

enum LCFridaConnectionPackage {
    static func create(app: LCAppInfo) throws -> URL {
        let config = try LCFridaSetup.config(app)
        guard let interaction = config["interaction"] as? [String: Any], interaction["type"] as? String == "listen",
              let port = interaction["port"] as? Int, (1...65535).contains(port),
              let token = interaction["token"] as? String, token.range(of: "^[a-f0-9]+$", options: .regularExpression) != nil,
              let folder = LCFridaSetup.folder(for: app),
              let resources = Bundle.main.url(forResource: "iOSVMFrida", withExtension: "bundle") else {
            throw "请先关闭自动脚本模式，并准备有效的电脑连接配置。"
        }
        let selection = try LCFridaScriptStore.selection(folder: folder)
        guard selection.owner == app.relativeBundlePath else { throw "请先在 Frida 页面更新此 App 的专属调试配置。" }
        guard let version = selection.gadgetVersion, version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else {
            throw "请先更新调试配置或选择已记录版本的 Gadget。"
        }
        let fm = FileManager.default
        let workspace = try LCManagedDirectory.temporaryWorkspace()
        defer { LCManagedDirectory.cleanup(workspace) }
        let scripts = workspace.appendingPathComponent("scripts")
        try fm.createDirectory(at: scripts, withIntermediateDirectories: false)
        let catalog = Dictionary(uniqueKeysWithValues: try LCFridaScriptStore.list().map { ($0.id, $0) })
        var names: [String] = []
        var index: [[String:String]] = []
        var total = 0
        for id in selection.computerScripts ?? [] {
            guard let script = catalog[id] else { throw "所选脚本已删除，请重新选择后导出。" }
            let label = String(script.name.prefix(32)).replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
            let name = id.uuidString + "-" + label + ".js"
            let source = try LCFridaScriptStore.source(script)
            let data = Data(try LCFridaScriptCompatibility.prepare(source, mode: script.effectiveBridgeMode).utf8)
            total += data.count
            guard total <= 32 * 1024 * 1024 else { throw "所选脚本总计不得超过 32 MiB。" }
            try data.write(to: scripts.appendingPathComponent(name), options: .atomic)
            names.append(name)
            index.append(["id":id.uuidString,"name":script.name,"file":name,"source":"computer"])
        }
        if names.isEmpty {
            names = ["connected.js"]
            try Data("console.log('iAppVM client connected');\n".utf8).write(to: scripts.appendingPathComponent(names[0]), options: .atomic)
        }
        try JSONSerialization.data(withJSONObject:index,options:[.prettyPrinted,.sortedKeys]).write(to:scripts.appendingPathComponent("index.json"),options:.atomic)
        try JSONSerialization.data(withJSONObject: ["interaction": interaction], options: [.prettyPrinted, .sortedKeys])
            .write(to: workspace.appendingPathComponent("FridaGadget.config"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspace.appendingPathComponent("FridaGadget.config").path)
        for name in ["frida-connect.py", "client-monitor.js"] {
            try fm.copyItem(at: resources.appendingPathComponent(name), to: workspace.appendingPathComponent(name))
        }
        let arguments = names.map { "--script scripts/" + $0 }.joined(separator: " ")
        let resume = interaction["on_load"] as? String == "wait" ? " --resume" : ""
        let guide = """
        iAppVM 电脑连接包 · Gadget \(version)

        此包包含此 App 的连接口令和电脑脚本选择（与手机自动脚本列表独立），请勿公开分享。
        解压后进入包含本 README 的目录。电脑需已安装 Python 3 与 iproxy。
        脚本名称对照见 scripts/index.json；未选电脑脚本时，仅附带连接诊断脚本。
        先启动手机上的目标 App；自动脚本模式应保持关闭。

        1. 准备匹配版本的客户端：
        python3 -m venv .venv
        .venv/bin/python -m pip install frida==\(version)

        2. 在一个终端运行 USB 转发：
        iproxy -s 127.0.0.1 27043:\(port)
        多台手机连接时，请加上 -u 设备UDID；电脑 27043 被占用时，改用空闲端口，并同步修改下面的 --address。

        3. 另一个终端进入同一目录后运行：
        .venv/bin/python frida-connect.py --address 127.0.0.1:27043 --config FridaGadget.config \(arguments)\(resume) --initialize-scripts --duration 3600 --output computer-session.json

        多个 --script 各自在独立上下文执行；--initialize-scripts 会调用已导出的 init(stage, {})。此客户端会向手机回传连接心跳与 console/send/error 日志；
        Ctrl+C 会卸载这些客户端脚本，目标 App 本身可以继续运行。
        普通 frida CLI 仍可使用，但不会自动回传连接状态和日志；实际脚本由 -l 参数决定。
        手机中请打开「电脑脚本回传日志」；computer-session.json 为本次电脑执行报告，不是手机自动运行日志。
        """
        try Data(guide.utf8).write(to: workspace.appendingPathComponent("README.txt"), options: .atomic)
        return try LCContainerExport.archive(source: workspace)
    }
}
