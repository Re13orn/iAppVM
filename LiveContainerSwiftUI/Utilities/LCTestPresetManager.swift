import Foundation

@MainActor enum LCTestPresetManager {
    static func networkURL(_ model: LCAppModel) -> URL {
        IOSVMGuestAccess.networkSettingsDirectory(documents:LCPath.docPath).appendingPathComponent(model.appInfo.relativeBundlePath + ".json")
    }
    static func network(_ model: LCAppModel) throws -> LCNetworkSettings {
        let url = networkURL(model)
        if FileManager.default.fileExists(atPath:url.path) {
            return try JSONDecoder().decode(LCNetworkSettings.self, from: LCFridaLogBoundary.readData(url, inside:LCPath.docPath, maximumBytes:16384))
        }
        let legacy = LCPath.docPath.appendingPathComponent("iOSVM/NetworkSettings/" + model.appInfo.relativeBundlePath + ".json")
        return FileManager.default.fileExists(atPath:legacy.path)
            ? try JSONDecoder().decode(LCNetworkSettings.self, from: LCFridaLogBoundary.readData(legacy, inside:LCPath.docPath, maximumBytes:16384))
            : LCNetworkSettings()
    }
    static func capture(_ model: LCAppModel, name: String, requireStopped: Bool = true) throws -> LCTestPresetStore.Preset {
        guard !requireStopped || !model.isAppRunning else { throw "请先关闭此 App，再保存当前配置，避免记录正在变化的设置。" }
        var preset = LCTestPresetStore.Preset(owner:model.appInfo.relativeBundlePath,name:name.trimmingCharacters(in:.whitespacesAndNewlines))
        preset.container = model.uiSelectedContainer?.folderName ?? model.uiContainers.first?.folderName
        preset.network = try network(model)
        if LCFridaSetup.enabled(model.appInfo), let folder = LCFridaSetup.folder(for:model.appInfo) {
            let selection = try LCFridaScriptStore.selection(folder:folder)
            guard selection.owner == preset.owner else { throw "请先在 Frida 调试中更新专属配置，再保存预设。" }
            guard let gadget = selection.gadgetID else { throw "Gadget 版本尚未记录，请先选择一个版本。" }
            preset.gadgetID = gadget; preset.gadgetVersion = selection.gadgetVersion
            preset.automatic = selection.automatic; preset.scripts = selection.scripts; preset.captureConsole = selection.captureConsole
        }
        try validate(preset,model:model)
        return preset
    }
    static func validate(_ preset: LCTestPresetStore.Preset, model: LCAppModel) throws {
        guard !model.appInfo.isShared else { throw "配置预设目前仅支持本地 App；共享 App 请在其所属宿主管理。" }
        let queue = LCPath.docPath.appendingPathComponent("iOSVM/SigningRequests/" + model.appInfo.relativeBundlePath + ".json")
        let request = try FileManager.default.fileExists(atPath:queue.path)
            ? LCFridaLogBoundary.readData(queue, inside:LCPath.docPath, maximumBytes:262144)
            : nil
        try LCTestPresetStore.requireIdleSigningRequest(request,owner:model.appInfo.relativeBundlePath)
        try LCTestPresetStore.validate(preset,owner:model.appInfo.relativeBundlePath,containers:Set(model.uiContainers.map(\.folderName)),
                                      scripts:Set(try LCFridaScriptStore.list().map(\.id)),gadgets:Set(try LCFridaVersions.versions().map(\.id)))
    }
    static func matches(_ preset: LCTestPresetStore.Preset, model: LCAppModel) -> Bool {
        guard let current = try? capture(model,name:preset.name,requireStopped:false) else { return false }
        return current.gadgetID == preset.gadgetID && current.automatic == preset.automatic && current.scripts == preset.scripts &&
            current.captureConsole == preset.captureConsole && current.network == preset.network &&
            (preset.container == nil || preset.container == current.container)
    }
    static func reload(_ model: LCAppModel) {
        if let disk = NSDictionary(contentsOfFile:model.appInfo.bundlePath() + "/LCAppInfo.plist") as? [String:Any] {
            model.appInfo.info().setDictionary(disk)
            model.uiTweakFolder = disk["LCTweakFolder"] as? String
            model.uiDefaultDataFolder = disk["LCDataUUID"] as? String
            model.uiSelectedContainer = model.uiContainers.first { $0.folderName == model.uiDefaultDataFolder } ?? model.uiContainers.first
            model.objectWillChange.send()
        }
    }
    static func apply(_ preset: LCTestPresetStore.Preset, model: LCAppModel) async throws {
        guard !model.isAppRunning else { throw "请先关闭此 App 的所有测试窗口，再应用预设。" }
        if matches(preset, model: model) { return }
        try validate(preset,model:model)
        let owner = model.appInfo.relativeBundlePath!
        guard !FileManager.default.fileExists(atPath:LCSettingsTransaction.url(owner:owner).path) else { throw "存在未完成切换，请先在启动诊断中恢复。" }
        let metadataURL = URL(fileURLWithPath:model.appInfo.bundlePath()).appendingPathComponent("LCAppInfo.plist")
        let before = try Data(contentsOf:metadataURL)
        guard var metadata = try PropertyListSerialization.propertyList(from:before,format:nil) as? [String:Any] else { throw "应用配置文件无效。" }
        let workspace = try LCManagedDirectory.temporaryWorkspace()
        defer { LCManagedDirectory.cleanup(workspace) }
        var published: URL?
        var committed = false
        defer { if !committed, let published { LCManagedDirectory.cleanup(published) } }
        if let id = preset.gadgetID {
            guard let existing = LCFridaSetup.folder(for:model.appInfo),
                  try LCFridaScriptStore.selection(folder:existing).owner == owner else { throw "请先在 Frida 调试中准备此 App 的专属 Gadget 配置。" }
            let selected = try LCFridaVersions.versions().first { $0.id == id }!
            let library = try LCFridaVersions.library(selected)
            let stage = workspace.appendingPathComponent("plugins")
            try FileManager.default.copyItem(at:existing,to:stage)
            let gadget = stage.appendingPathComponent("FridaGadget.dylib")
            if FileManager.default.fileExists(atPath:gadget.path) { try FileManager.default.removeItem(at:gadget) }
            try FileManager.default.copyItem(at:library,to:gadget)
            var selection = try LCFridaScriptStore.selection(folder:stage)
            selection.owner = owner; selection.gadgetID = id; selection.gadgetVersion = selected.version
            selection.automatic = preset.automatic; selection.scripts = preset.scripts; selection.captureConsole = preset.captureConsole
            try LCFridaScriptStore.apply(selection,folder:stage)
            try await LCUtils.signTweaks(tweakFolderUrl:stage,force:true)
            // No await after this guard until the transaction has been published.
            guard !model.isAppRunning else { throw "准备期间目标已经启动，配置切换已取消。" }
            try validate(preset,model:model)
            let name = "iOSVM-Frida-" + String(owner.prefix(100)) + "-" + UUID().uuidString
            let destination = LCPath.tweakPath.appendingPathComponent(name)
            try FileManager.default.moveItem(at:stage,to:destination)
            published = destination
            metadata["LCTweakFolder"] = name
            metadata["IOSVMSigningGeneration"] = UUID().uuidString
            metadata["IOSVMNeedsExternalSigning"] = true
            metadata["IOSVMDeviceSigned"] = false; metadata["IOSVMExternallySigned"] = false
        } else if LCFridaSetup.enabled(model.appInfo) {
            // A preset without Gadget cannot silently inherit subsequently enabled startup scripts.
            throw "此预设未包含 Gadget，但当前已启用。请先保存包含当前 Gadget 的预设，避免模式被意外继承。"
        }
        if let container = preset.container { metadata["LCDataUUID"] = container }

        metadata["IOSVMActiveTestPreset"] = preset.id.uuidString
        let presetEncoder = JSONEncoder(); presetEncoder.outputFormatting = .sortedKeys
        metadata["IOSVMActiveTestPresetDigest"] = LCFridaScriptStore.digest(try presetEncoder.encode(preset))
        let networkFile = networkURL(model)
        try LCManagedDirectory.ensureWritable(networkFile.deletingLastPathComponent(),inside:LCPath.docPath)
        let oldNetwork = try FileManager.default.fileExists(atPath:networkFile.path) ? Data(contentsOf:networkFile) : nil
        func relative(_ url: URL) throws -> String {
            guard LCFridaScriptStore.isManaged(url,inside:LCPath.docPath) else { throw "配置路径超出本地 App 范围。" }
            return String(url.standardizedFileURL.path.dropFirst(LCPath.docPath.standardizedFileURL.path.count+1))
        }
        let changes = [
            LCSettingsTransaction.Change(path:try relative(networkFile),before:oldNetwork,after:try JSONEncoder().encode(preset.network)),
            LCSettingsTransaction.Change(path:try relative(metadataURL),before:before,after:try PropertyListSerialization.data(fromPropertyList:metadata,format:.xml,options:0))
        ]
        guard !model.isAppRunning else { throw "目标已启动，配置切换已取消。" }
        do { try LCSettingsTransaction.apply(owner:owner,changes:changes) }
        catch {
            // Keep a referenced staged folder if crash recovery still needs either generation.
            if FileManager.default.fileExists(atPath:LCSettingsTransaction.url(owner:owner).path) { committed = true }
            reload(model); throw error
        }
        committed = true
        reload(model)
        if let published {
            let shared = DataManager.shared.model
            if !shared.tweakFolderNames.contains(published.lastPathComponent) { shared.tweakFolderNames.append(published.lastPathComponent) }
        }
    }
}
