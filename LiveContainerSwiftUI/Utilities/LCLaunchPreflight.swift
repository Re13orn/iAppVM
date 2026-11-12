import Foundation

enum LCLaunchPreflight {
    enum Action: String { case signing, frida, scripts, containers, network, process, settings, recover, backups }
    struct Issue: Identifiable {
        let id: String
        let title: String
        let detail: String
        let blocking: Bool
        let action: Action?
    }
    struct Failure: LocalizedError {
        let issues: [Issue]
        var errorDescription: String? { "启动前自检未通过：\n" + issues.filter(\.blocking).map { $0.title + "：" + $0.detail }.joined(separator:"\n") }
    }
    /// Reads expiry metadata only; never claims to cryptographically validate a signed app.
    static func profileExpiry(_ data: Data) -> Date? {
        guard data.count < 4 * 1024 * 1024,
              let start = data.range(of:Data("<?xml".utf8)), let end = data.range(of:Data("</plist>".utf8),in:start.lowerBound..<data.endIndex),
              let value = try? PropertyListSerialization.propertyList(from:data.subdata(in:start.lowerBound..<end.upperBound),format:nil) as? [String:Any] else { return nil }
        return value["ExpirationDate"] as? Date
    }
    @MainActor static func check(_ model: LCAppModel, multitask: Bool? = nil) -> [Issue] {
        var issues: [Issue] = []
        let app = model.appInfo, owner = app.relativeBundlePath!
        func add(_ id: String, _ title: String, _ detail: String, _ blocking: Bool = true, _ action: Action? = nil) {
            issues.append(Issue(id:id,title:title,detail:detail,blocking:blocking,action:action))
        }
        if FileManager.default.fileExists(atPath:LCSettingsTransaction.url(owner:owner).path) {
            add("transaction","上次配置切换未完成","先恢复原配置，再签名或启动。",true,.recover)
        }
        if !FileManager.default.fileExists(atPath:app.bundlePath()+"/Info.plist") { add("bundle","应用文件缺失","请检查导入是否完整；不要删除数据容器。",true,.containers) }
        if let selected = model.uiSelectedContainer, !model.uiContainers.contains(where:{$0.folderName == selected.folderName}) {
            add("container","选中容器不属于此 App","请重新选择此 App 的数据容器。",true,.containers)
        }
        if let selected = model.uiSelectedContainer, selected.storageBookMark == nil,
           !FileManager.default.fileExists(atPath:selected.containerURL.path) {
            add("container-files","数据容器目录缺失","请恢复原目录或重新选择容器，不会自动重建覆盖。",true,.containers)
        }
        if let container = model.uiSelectedContainer ?? model.uiContainers.first,
           let context = try? LCSandboxBackupManager.context(model, container), LCSandboxBackupStore.pending(context) {
            add("sandbox-restore", "沙盒恢复尚未整理完成", "进入沙盒备份与比较，确认并完成上次恢复的整理。", true, .backups)
        }
        let wantsWindow = multitask ?? model.shouldLaunchInMultitaskMode
        if wantsWindow && app.defaultClassicMode != 0 { add("classic","运行模式不支持独立窗口","到应用设置选择合适运行模式。",true,.settings) }
        if wantsWindow && LCUtils.liveProcessBundleIdentifier() == nil { add("extension","缺少独立窗口扩展","需要安装带有效 LiveProcess 扩展的宿主。",true,.settings) }
        if let url = Bundle.main.url(forResource:"embedded",withExtension:"mobileprovision"), let data = try? Data(contentsOf:url), let expiry = profileExpiry(data) {
            if expiry <= Date() { add("host-expired","iAppVM 描述文件已过期","请续签并覆盖安装宿主，保留现有数据。",true,.settings) }
            else if expiry.timeIntervalSinceNow < 3*86400 { add("host-expiry","iAppVM 即将需要续签","描述文件有效期至 " + expiry.formatted(date:.abbreviated,time:.omitted) + "。",false,.settings) }
        }
        let disk = NSDictionary(contentsOfFile:app.bundlePath()+"/LCAppInfo.plist") as? [String:Any] ?? app.info() as? [String:Any] ?? [:]
        var needsSign = disk["IOSVMNeedsExternalSigning"] as? Bool == true
        let requestURL = LCPath.docPath.appendingPathComponent("iOSVM/SigningRequests/"+owner+".json")
        if let data = try? LCFridaLogBoundary.readData(requestURL, inside:LCPath.docPath, maximumBytes:262144) {
            if let request = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let state = request["state"] as? String {
                let generation = disk["IOSVMSigningGeneration"] as? String
                let matchesGeneration = generation == nil || request["id"] as? String == generation
                needsSign = needsSign || state != "ready" || !matchesGeneration
            } else { add("sign-request","签名状态记录无法读取","请重新签名生成有效记录。",true,.signing) }
        }
        if let expiry = disk["LCExpirationDate"] as? Date, expiry <= Date() { needsSign = true }
        var keyError: String?
        if IOSVMDeviceSigning.configured, let key = LCUtils.certificateData(), let password = LCSharedUtils.certificatePassword() {
            keyError = LCUtils.validateSigningKey(key,password:password)
        }
        if needsSign {
            if let keyError { add("signing","签名身份需要更新",keyError,true,.signing) }
            else if IOSVMDeviceSigning.configured { add("signing","配置已变更，需要重新签名","可在此页完成；直接启动时也会尝试手机签名。",false,.signing) }
            else { add("signing","尚未完成签名","先配置匹配的手机签名证书，或完成当前电脑签名流程。",true,.signing) }
        } else if let keyError { add("sign-key","已保存的签名身份不可用于续签",keyError,false,.signing) }
        do {
            let network = try LCTestPresetManager.network(model); try network.validate()
        } catch { add("network","网络配置无效",error.localizedDescription,true,.network) }
        if let folder = LCFridaSetup.folder(for:app) {
            do {
                guard LCFridaScriptStore.isManaged(folder,inside:app.isShared ? LCPath.lcGroupTweakPath : LCPath.tweakPath) else { throw "插件目录包含链接或越界路径。" }
                let selection = try LCFridaScriptStore.selection(folder:folder)
                if selection.automatic {
                    if selection.owner != owner { add("frida-owner","启动脚本归属不匹配","到 Frida 调试更新此 App 的专属配置。",true,.frida) }
                    if !LCFridaSetup.enabled(app) || app.dontLoadTweakLoader || app.dontInjectTweakLoader { add("frida-loader","自动脚本无法加载 Gadget","请启用此 App 的 Gadget 与 TweakLoader。",true,.frida) }
                    let catalog = Dictionary(uniqueKeysWithValues:try LCFridaScriptStore.list().map { ($0.id,$0) })
                    var total = 0
                    for id in selection.scripts {
                        guard let script = catalog[id] else { throw "选中的启动脚本已被删除，请重新选择。" }
                        total += try LCFridaScriptStore.source(script).utf8.count
                    }
                    if selection.scripts.isEmpty || selection.scripts.count > 32 || total > 32*1024*1024 { throw "启动脚本数量或大小无效，请重新选择。" }
                }
                if LCFridaSetup.enabled(app) {
                    let config = try LCFridaSetup.config(app)
                    let interaction = config["interaction"] as? [String:Any] ?? [:]
                    let mode = interaction["type"] as? String
                    if mode != (selection.automatic ? "script-directory" : "listen") { add("frida-mode","脚本模式与 Gadget 配置不一致","请重新保存启动脚本配置。",true,.scripts) }
                    if !selection.automatic && interaction["on_load"] as? String == "wait" { add("frida-wait","目标将等待电脑连接","启动时可能暂时白屏；请使用当前连接包加载脚本并 resume。",false,.frida) }
                }
            } catch { add("scripts","Frida 配置或脚本不可用",error.localizedDescription,true,.scripts) }
        }
        return issues.sorted { $0.blocking && !$1.blocking }
    }
}
