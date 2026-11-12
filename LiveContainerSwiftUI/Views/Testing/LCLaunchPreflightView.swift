import SwiftUI

/// Keep existing launch-failure routes pointed at the same diagnostic surface.
struct LCLaunchPreflightView: View {
    @ObservedObject var model: LCAppModel
    var body: some View { LCCompatibilityDiagnosticsView(model: model) }
}

struct LCLaunchPreflightChecks: View {
    @ObservedObject var model: LCAppModel
    @Binding var issues: [LCLaunchPreflight.Issue]
    @Binding var busy: Bool
    var didRefresh: () -> Void
    @State private var message: String?
    var body: some View {
        Group {
            Section {
                Button("重新检查",action:reload).disabled(busy)
            } header: { Text("lc.tools.configurationChecks".loc) }
            if issues.isEmpty {
                Section { Label("基础配置检查通过",systemImage:"checkmark.circle").foregroundStyle(Color.accentColor) }
            }
            ForEach(issues) { issue in
                Section {
                    Label(issue.title,systemImage:issue.blocking ? "exclamationmark.octagon" : "info.circle")
                        .font(.headline).foregroundStyle(issue.blocking ? Color.red : Color.primary)
                    Text(issue.detail).font(.subheadline).foregroundStyle(.secondary)
                    if let action = issue.action { repair(action) }
                } header: { Text(issue.blocking ? "需要处理" : "提示") }
            }
            Section {
                Button { Task { await launch() } } label: { Label("检查并启动",systemImage:"play.fill") }
                    .disabled(busy || model.isAppRunning || issues.contains(where: \.blocking))
                if busy { ProgressView("正在处理…") }
            } footer: { Text("检查配置、文件引用和离线签名身份信息；不会把签名记录当作运行时验签结果，也不会读取 App 的业务数据。") }
        }
        .alert("lc.tools.launchDiagnostics".loc,isPresented:Binding(get:{message != nil},set:{if !$0 {message=nil}})) { Button("确定") {message=nil} } message: { Text(message ?? "") }
    }
    @ViewBuilder private func repair(_ action: LCLaunchPreflight.Action) -> some View {
        switch action {
        case .signing:
            if IOSVMDeviceSigning.configured {
                Button("在手机重新签名") { Task { await sign() } }.disabled(busy || model.isAppRunning)
            }
            NavigationLink("打开签名与宿主设置") { LCSettingsView() }
        case .frida: NavigationLink("打开 Frida 调试") { LCFridaView(model:model) }
        case .scripts: NavigationLink("检查启动脚本") { LCFridaStartupScriptsView(model:model) }
        case .network: NavigationLink("检查捕获与代理") { LCNetworkView(model:model) }
        case .containers, .settings: NavigationLink("打开应用设置") { LCAppSettingsView(model:model) }
        case .process: NavigationLink("查看运行状态") { LCGuestSessionView(model:model) }
        case .backups: NavigationLink("打开沙盒备份与比较") { LCSandboxBackupsView(model:model) }
        case .recover:
            Button("恢复切换前的配置") {
                do {
                    guard !model.isAppRunning else { throw "请先关闭目标 App。" }
                    try LCSettingsTransaction.recover(owner:model.appInfo.relativeBundlePath)
                    LCTestPresetManager.reload(model); reload()
                } catch { message=error.localizedDescription }
            }.disabled(busy || model.isAppRunning)
        }
    }
    private func reload() { didRefresh() }
    @MainActor private func sign() async {
        busy=true; defer {busy=false;reload()}
        do {try await IOSVMDeviceSigning.sign(model.appInfo);LCTestPresetManager.reload(model)} catch {message=error.localizedDescription}
    }
    @MainActor private func launch() async {
        reload();guard !issues.contains(where: \.blocking) else {return}
        busy=true;defer {busy=false;reload()}
        do {try await model.runApp()} catch {message=error.localizedDescription}
    }
}
