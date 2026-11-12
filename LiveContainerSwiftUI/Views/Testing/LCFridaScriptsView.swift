import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LCFridaScriptLibraryView: View {
    @State private var scripts: [LCFridaScriptStore.Script] = []
    @State private var importPresented = false
    @State private var newPresented = false
    @State private var message: String?
    @State private var removing: LCFridaScriptStore.Script?
    var body: some View {
        List {
            Section {
                Button { importPresented = true } label: { Label("导入 JavaScript", systemImage: "square.and.arrow.down") }
                Button { newPresented = true } label: { Label("新建脚本", systemImage: "square.and.pencil") }
                NavigationLink { LCFridaScriptMarketView() } label: {
                    LCToolRow(title: "lc.market.title".loc, subtitle: "lc.market.entry.desc".loc, symbol: "square.grid.2x2")
                }
            } footer: { Text("脚本存入全局库，在每个 App 的 Frida 页面单独选择。导入时检查依赖；常见 ObjC 脚本可自动补齐桥接。原文保留在库中，运行时生成副本。其他模块和 Swift 桥接需在电脑打包。") }
            if scripts.isEmpty {
                LCToolEmptyState(title: "还没有脚本", message: "导入或新建 JS 后，即可为不同 App 组合启动脚本。", symbol: "doc.text")
            }
            ForEach(scripts) { script in
                NavigationLink { LCFridaScriptEditor(script: script) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(script.name).lineLimit(2)
                        Text(script.effectiveBridgeMode.title + " · " + script.modifiedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.swipeActions { Button("删除", role: .destructive) { removing = script } }
            }
        }
        .navigationTitle("Frida 脚本库").navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(isPresented: $newPresented, onDismiss: reload) { NavigationView { LCFridaScriptEditor(script: nil) } }
        .betterFileImporter(isPresented: $importPresented, types: [.javaScript, .plainText, .item], callback: { urls in
            do {
                var reports: [String] = []
                for url in urls { reports.append(try LCFridaScriptStore.importFile(url)) }
                reload()
                message = reports.joined(separator: "\n\n")
            }
            catch { message = error.localizedDescription }
        }, onDismiss: { importPresented = false })
        .alert("删除脚本？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("删除", role: .destructive) {
                do { if let removing { try LCFridaScriptStore.remove(removing) }; self.removing = nil; reload() }
                catch { message = error.localizedDescription }
            }
        } message: { Text("正在运行的脚本不会被卸载。仍引用它的 App 下次启动会提示重新选择，避免悄悄运行旧副本。") }
        .alert("脚本库", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
    private func reload() { do { scripts = try LCFridaScriptStore.list() } catch { message = error.localizedDescription } }
}

struct LCFridaScriptEditor: View {
    let script: LCFridaScriptStore.Script?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var source = ""
    @State private var message: String?
    @State private var exportURL: URL?
    @State private var loaded = false
    @State private var bridgeMode = LCFridaScriptCompatibility.BridgeMode.automatic
    @State private var report: LCFridaScriptCompatibility.Report?
    @State private var checkedSource: String?
    @State private var checking = false
    var body: some View {
        Form {
            Section("名称") { TextField("例如 network-observer.js", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled() }
            Section {
                Picker("桥接处理", selection: $bridgeMode) {
                    ForEach(LCFridaScriptCompatibility.BridgeMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                Button { checkDependencies()
                } label: {
                    if checking { ProgressView("正在检查依赖") } else { Label("检查脚本依赖", systemImage: "checkmark.magnifyingglass") }
                }.disabled(checking || !loaded)
                if let report {
                    if checkedSource != source { Text("内容已修改，请重新检查。").foregroundStyle(.orange) }
                    else {
                        ForEach(Array(report.notes.enumerated()), id: \.offset) { item in
                            Text(item.element).font(.footnote).foregroundStyle(.secondary)
                        }
                        if bridgeMode != .unchanged && (report.modules || report.syntaxError != nil || (bridgeMode == .objc && (report.packaged || report.topObjC))) {
                            Text("当前模式下无法准备运行副本，请先处理以上问题。").font(.footnote).foregroundStyle(.orange)
                        } else if report.addsObjC(bridgeMode) { Label("运行副本将补齐 ObjC 桥接", systemImage: "link").font(.footnote) }
                        else { Text("运行副本保持原有桥接方式。").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            } header: { Text("依赖与兼容性") } footer: {
                Text("静态检查不会执行脚本，也不能证明 Hook 可用。补齐 ObjC 不会改变签名权限或自动调用脚本函数；保持原样可关闭自动处理。")
            }
            Section("JavaScript") {
                LCCodeEditor(text: $source).frame(minHeight: 340)
            }
            Section {
                Button("导出当前内容") {
                    do {
                        let folder = try LCManagedDirectory.temporaryWorkspace()
                        let file = folder.appendingPathComponent("script.js")
                        try Data(source.utf8).write(to: file, options: .atomic)
                        exportURL = file
                    } catch { message = error.localizedDescription }
                }
                if #available(iOS 16.0, *), let exportURL { ShareLink("分享 JS 文件", item: exportURL) }
            } footer: { Text("修改库中的脚本会在使用它的 App 下次启动时更新副本。保存不表示代码已通过 Frida 编译或 Hook 权限检查。") }
        }
        .navigationTitle(script == nil ? "新建脚本" : "编辑脚本").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("保存") {
                do { try LCFridaScriptStore.save(id: script?.id, name: name, source: source, bridgeMode: bridgeMode); dismiss() }
                catch { message = error.localizedDescription }
            }.disabled(!loaded)
        } }
        .onAppear {
            guard !loaded else { return }
            do {
                if let script { name = script.name; source = try LCFridaScriptStore.source(script); bridgeMode = script.effectiveBridgeMode }
                else { name = "new-script.js"; source = "console.log('script started');\n" }
                loaded = true
                checkDependencies()
            } catch { message = error.localizedDescription }
        }
        .alert("脚本", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func checkDependencies() {
        guard !checking else { return }
        let candidate = source
        checking = true
        Task {
            do {
                let result = try await Task.detached { try LCFridaScriptCompatibility.inspect(candidate) }.value
                report = result; checkedSource = candidate
            } catch { message = error.localizedDescription }
            checking = false
        }
    }
}

struct LCFridaStartupScriptsView: View {
    @ObservedObject var model: LCAppModel
    var computer = false
    @State private var selection = LCFridaScriptStore.Selection()
    @State private var scripts: [LCFridaScriptStore.Script] = []
    @State private var message: String?
    @State private var loaded = false
    @State private var synchronizationNotice: String?
    private var chosen: [UUID] { computer ? (selection.computerScripts ?? []) : selection.scripts }
    private func choose(_ ids: [UUID]) {
        if computer { selection.computerScripts = ids } else { selection.scripts = ids }
    }
    var body: some View {
        Form {
            Section {
                Label(computer ? "电脑连接脚本" : "手机自动脚本", systemImage: computer ? "desktopcomputer" : "iphone").font(.headline)
                if let synchronizationNotice {
                    Text(synchronizationNotice).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle(computer ? "下次启动使用电脑连接" : "下次启动在手机自动运行", isOn: Binding(get: { computer ? !selection.automatic : selection.automatic }, set: { selection.automatic = computer ? !$0 : $0 }))
                Toggle("记录脚本输出与进程控制台", isOn: $selection.captureConsole)
                DisclosureGroup("运行方式与限制") {
                    Text("本地脚本模式不监听电脑连接；关闭自动运行可恢复原端口、口令和等待设置。手机脚本输出单独记录；App 的 stdout/stderr 留在进程控制台，各自最多 4 MiB。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text(computer ? "此页选择仅用于电脑连接包，不会在手机上自动执行。未选脚本时只附带连接诊断。普通 CLI 实际运行的脚本以电脑 -l 参数为准。" : "此页选择只用于手机自动运行，与电脑脚本选择分开。两种运行方式切换后需保存并重新启动目标。")
            }
            Section {
                NavigationLink { LCFridaScriptLibraryView() } label: { Label("共用脚本库", systemImage: "books.vertical") }
            }
            Section {
                NavigationLink { LCAppLogsView(model:model, initialSource:computer ? .computer : .phone) } label: {
                    Label(computer ? "查看电脑回传日志" : "查看手机自动运行日志",systemImage:computer ? "desktopcomputer" : "iphone")
                }
            }
            Section {
                if scripts.isEmpty { Text("先到脚本库导入或新建 JS。").foregroundStyle(.secondary) }
                ForEach(scripts) { script in
                    Toggle(isOn: Binding(get: { chosen.contains(script.id) }, set: { value in
                        if value { choose(chosen + [script.id]) } else { choose(chosen.filter { $0 != script.id }) }
                    })) { Text(script.name).lineLimit(2) }
                }
                let missing = chosen.filter { id in !scripts.contains(where: { $0.id == id }) }
                if !missing.isEmpty {
                    Button("移除 \(missing.count) 个已删除的脚本引用") { choose(chosen.filter { !missing.contains($0) }) }
                }
            } header: { Text((computer ? "电脑连接包脚本" : "手机自动运行脚本") + " · 已选 \(chosen.count)") } footer: {
                Text("最多 32 个脚本、总计 32 MiB，各自独立加载。勾选顺序仅用于保存列表，不保证多个脚本的异步初始化先后；存在依赖时应合并成一个已打包脚本。")
            }
            Section {
                Toggle("允许通用 Interceptor Hook（需要 JIT）", isOn: Binding(
                    get: { selection.allowGenericHooks == true },
                    set: { value in
                        let wasEnabled = selection.allowGenericHooks == true
                        selection.allowGenericHooks = value
                        if value || wasEnabled { model.uiIsJITNeeded = value }
                    }
                ))
            } header: { Text("Hook 能力") } footer: {
                Text("开启后 Gadget 使用 code_signing=optional，允许通用 Interceptor/Stalker 修改目标代码；同时会启用目标的 JIT 启动。必须先配置可用的 JIT 启动方式，否则 Hook 仍会被系统拒绝。关闭时保持 code_signing=required。")
            }
            Section {
                Button(computer ? "保存电脑脚本与连接方式" : "保存手机脚本与运行方式") {
                    do {
                        guard !model.isAppRunning else { throw "请先关闭此 App 的测试窗口。" }
                        guard let folder = LCFridaSetup.folder(for: model.appInfo) else { throw "请先启用 Gadget。" }
                        guard selection.owner == model.appInfo.relativeBundlePath else { throw "当前调试目录尚未归属于此 App。请返回 Frida 页面，点击更新调试配置，建立专属配置后再保存。" }
                        try LCFridaScriptStore.apply(selection, folder: folder)
                        model.uiIsJITNeeded = selection.allowGenericHooks == true
                        model.appInfo.save()
                        selection = try LCFridaScriptStore.selection(folder: folder)
                        message = computer ? "电脑脚本选择已保存；请重新生成连接包。运行方式在下次启动生效。" : "手机脚本选择已保存，下次启动此 App 生效。"
                    } catch { message = error.localizedDescription }
                }.disabled(!loaded || model.isAppRunning)
            } footer: { Text(model.isAppRunning ? "关闭目标后才能保存；正在运行的脚本不会被此页面热替换。" : "配置仅应用于这个安装实例。自动执行不会扩大 Hook 权限；签名受限模式下的 Interceptor 目标仍需预插桩。") }
        }
        .navigationTitle(computer ? "电脑连接脚本" : "手机自动脚本").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do {
                scripts = try LCFridaScriptStore.list()
                if let folder = LCFridaSetup.folder(for: model.appInfo) {
                    let saved = try LCFridaScriptStore.selection(folder: folder)
                    // Returning from built-in scripts may have changed this app's
                    // saved selection. Keep an unsaved draft only while its revision
                    // is still current; never save it over a newer attachment.
                    if !loaded || saved.revision != selection.revision {
                        if loaded { synchronizationNotice = "lc.tools.scriptSelectionSynced".loc }
                        selection = saved
                        loaded = true
                    }
                }
            } catch { message = error.localizedDescription }
        }
        .alert(computer ? "电脑连接脚本" : "手机自动脚本", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
}

struct LCCodeEditor: UIViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.autocorrectionType = .no; view.autocapitalizationType = .none; view.spellCheckingType = .no
        view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .interactive
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LCCodeEditor
        init(_ parent: LCCodeEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}
