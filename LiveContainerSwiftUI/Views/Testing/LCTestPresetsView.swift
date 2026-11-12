import SwiftUI

struct LCTestPresetsView: View {
    @ObservedObject var model: LCAppModel
    @State private var presets: [LCTestPresetStore.Preset] = []
    @State private var name = ""
    @State private var naming = false
    @State private var deleting: LCTestPresetStore.Preset?
    @State private var message: String?
    var body: some View {
        List {
            Section {
                LCToolContext(model:model,title:"lc.tools.configurationPresets".loc,subtitle:"保存当前组合，关闭目标后集中切换。",symbol:"slider.horizontal.3")
                Button("将当前配置保存为预设") { name="";naming=true }.disabled(model.isAppRunning || model.appInfo.isShared)
                if model.isAppRunning { Text("先关闭目标 App，再保存或应用配置。").font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text("保存 Gadget 版本、脚本选择与自动模式、控制台、代理/捕获选项和所选数据容器。保存引用，不复制沙盒数据或认证口令。") }
            if presets.isEmpty { LCToolEmptyState(title:"还没有预设",message:"先配置一次 App，再保存为“正常运行”“网络分析”等组合。",symbol:"slider.horizontal.3") }
            ForEach(presets) { preset in
                NavigationLink { LCTestPresetDetailView(model:model,preset:preset) } label: {
                    VStack(alignment:.leading,spacing:5) {
                        Text(preset.name).font(.headline)
                        Text((preset.gadgetVersion ?? "保持无 Gadget") + " · " + (preset.automatic ? "自动脚本 \(preset.scripts.count) 个" : "电脑监听/无自动脚本") + " · " + preset.network.proxyType.uppercased()).font(.caption).foregroundStyle(.secondary)
                        if model.appInfo.info()["IOSVMActiveTestPreset"] as? String == preset.id.uuidString { Text(LCTestPresetManager.matches(preset,model:model) ? "当前配置匹配 · 签名状态见启动诊断" : "最近应用 · 当前设置已改变").font(.caption).foregroundStyle(Color.accentColor) }
                    }.padding(.vertical,4)
                }.swipeActions { Button(role:.destructive) {deleting=preset} label: {Label("删除",systemImage:"trash")} }
            }
            Section { NavigationLink("lc.tools.launchDiagnostics".loc) {LCLaunchPreflightView(model:model)} }
        }
        .navigationTitle("lc.tools.configurationPresets".loc).navigationBarTitleDisplayMode(.inline).onAppear(perform:reload)
        .sheet(isPresented:$naming) {
            NavigationView {
                Form {
                    TextField("预设名称",text:$name)
                    Button("保存当前组合") {
                        do { let preset=try LCTestPresetManager.capture(model,name:name);try LCTestPresetStore.save(preset);naming=false;reload() }
                        catch {message=error.localizedDescription;naming=false}
                    }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }.navigationTitle("保存预设").toolbar { ToolbarItem(placement:.cancellationAction) {Button("取消") {naming=false}} }
            }
        }
        .alert("删除预设？",isPresented:Binding(get:{deleting != nil},set:{if !$0{deleting=nil}})) {
            Button("删除",role:.destructive) { do {if let deleting {try LCTestPresetStore.remove(deleting)};reload()} catch {message=error.localizedDescription};deleting=nil }
            Button("取消",role:.cancel) {deleting=nil}
        } message: {Text("只删除配置记录，不改变当前设置、脚本或沙盒数据。")}
        .alert("测试配置",isPresented:Binding(get:{message != nil},set:{if !$0{message=nil}})) { Button("确定") {message=nil} } message: {Text(message ?? "")}
    }
    private func reload() {do{presets=try LCTestPresetStore.list(owner:model.appInfo.relativeBundlePath)}catch{message=error.localizedDescription}}
}

private struct LCTestPresetDetailView: View {
    @ObservedObject var model: LCAppModel
    @State var preset: LCTestPresetStore.Preset
    @State private var busy=false
    @State private var message: String?
    @State private var confirm=false
    @State private var rename=""
    @State private var renaming=false
    @State private var replace=false
    private var containerName: String {
        guard let index=model.uiContainers.firstIndex(where:{$0.folderName==preset.container}) else {return preset.container == nil ? "保持默认；首次启动时创建" : "引用的容器已不存在"}
        let container=model.uiContainers[index]
        return container.name==container.folderName ? "沙盒 \(index+1)" : container.name
    }
    @State private var scriptNames: [UUID:String] = [:]
    var body: some View {
        Form {
            Section("预设内容") {
                Text(preset.name).font(.headline)
                value("数据容器",containerName)
                value("Gadget",preset.gadgetVersion ?? "不包含 Gadget")
                value("模式",preset.automatic ? "本地自动脚本" : "无自动脚本/电脑监听")
                DisclosureGroup("脚本组合（\(preset.scripts.count) 个）") {
                    ForEach(preset.scripts,id:\.self) {id in Text(scriptNames[id] ?? "脚本已删除 · " + id.uuidString).font(.subheadline)}
                }
                value("记录控制台",preset.captureConsole ? "开启" : "关闭")
                value("网络捕获",preset.network.capture ? (preset.network.bodies ? "请求与正文" : "请求信息") : "关闭")
                value("代理",preset.network.proxyType == "off" ? "关闭" : preset.network.proxyType.uppercased()+" · "+preset.network.host+":"+String(preset.network.port))
            }
            Section {
                Text("将替换当前的脚本组合、Gadget、代理与捕获设置，并切换所选数据容器。不会覆盖或删除容器文件。")
                if let error=validationError {Text(error).foregroundStyle(.red)}
                Button("应用此预设") {confirm=true}.disabled(busy || model.isAppRunning || validationError != nil)
                if busy {ProgressView("正在准备与应用…")}
                NavigationLink("lc.tools.launchDiagnostics".loc) {LCLaunchPreflightView(model:model)}
            } header: {Text("应用前检查")} footer: {Text("目标必须关闭。Gadget 配置在独立目录准备；应用失败恢复原设置。涉及 Gadget 的切换需重新签名，启动时可使用已配置的手机证书完成。")}
            Section("管理") {
                Button("重命名") {rename=preset.name;renaming=true}.disabled(busy)
                Button("用当前设置更新此预设") {replace=true}.disabled(busy || model.isAppRunning)
            }
        }.navigationTitle("预设详情").navigationBarTitleDisplayMode(.inline)
        .onAppear {scriptNames=Dictionary(uniqueKeysWithValues:((try? LCFridaScriptStore.list()) ?? []).map{($0.id,$0.name)})}
        .confirmationDialog("应用“\(preset.name)”？",isPresented:$confirm,titleVisibility:.visible) {
            Button("应用配置并保留原目录") {Task{await apply()}}
        }
        .confirmationDialog("用当前设置覆盖预设内容？",isPresented:$replace,titleVisibility:.visible) {
            Button("更新预设") {
                do {var value=try LCTestPresetManager.capture(model,name:preset.name);value.id=preset.id;try LCTestPresetStore.save(value);preset=value}
                catch {message=error.localizedDescription}
            }
        }
        .sheet(isPresented:$renaming) { NavigationView {Form {
            TextField("名称",text:$rename)
            Button("保存") {do {var value=preset;value.name=rename.trimmingCharacters(in:.whitespacesAndNewlines);value.modifiedAt=Date();try LCTestPresetStore.save(value);preset=value;renaming=false}catch{renaming=false;message=error.localizedDescription}}
        }.navigationTitle("重命名").toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){renaming=false}}}} }
        .alert("测试配置",isPresented:Binding(get:{message != nil},set:{if !$0{message=nil}})) {Button("确定"){message=nil}} message:{Text(message ?? "")}
    }
    private var validationError: String? {do{try LCTestPresetManager.validate(preset,model:model);return nil}catch{return error.localizedDescription}}
    private func value(_ label:String,_ value:String) -> some View {HStack(alignment:.firstTextBaseline){Text(label);Spacer();Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)}}
    @MainActor private func apply() async {
        busy=true;defer{busy=false}
        do {try await LCTestPresetManager.apply(preset,model:model);message=preset.gadgetID == nil ? "配置已应用，下次启动使用此预设。" : "配置已应用。请到启动诊断完成签名，或直接启动自动签名；原插件目录保留。"}
        catch{message=error.localizedDescription}
    }
}
