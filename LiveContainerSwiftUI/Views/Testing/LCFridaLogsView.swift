import SwiftUI
import UIKit

struct LCDebugSession {
    let folder: URL
    let value: [String: Any]
    var id: String { folder.lastPathComponent }
    var pid: Int { value["pid"] as? Int ?? 0 }
    var console: URL { folder.appendingPathComponent("console.log") }
    static func list(root: URL) -> [LCDebugSession] {
        let base = root.appendingPathComponent("Library/iOSVM/Sessions")
        guard (try? LCFridaLogBoundary.directory(base, inside: root)) != nil else { return [] }
        let folders = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { $0.lastPathComponent.hasPrefix("session-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }.compactMap { folder in
            guard (try? LCFridaLogBoundary.directory(folder, inside: root)) != nil,
                  let data = try? LCFridaLogBoundary.readData(folder.appendingPathComponent("session.json"), inside: root, maximumBytes: 128 * 1024),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return LCDebugSession(folder: folder, value: value)
        }
    }
}

struct LCFridaLogsView: View {
    @ObservedObject var model: LCAppModel
    var showsSourcePicker = true
    @State private var sessions: [LCDebugSession] = []
    @State private var selected = ""
    @State private var text = ""
    @State private var query = ""
    @State private var paused = false
    @State private var wraps = true
    @State private var copied = false
    @State private var failure: String?
    @State private var source: LCFridaLogSource
    @State private var clients: [URL] = []
    @State private var showDuplicateWarnings = false
    @State private var hiddenWarnings = 0
    @State private var exportURL: URL?
    @State private var exportFolder: URL?
    @State private var sharing = false
    @State private var selectedClient = ""
    @State private var clearRequest: ClearRequest?
    @State private var notice: String?
    @State private var command = ""
    @State private var commandScriptID = ""
    @State private var sendingCommand = false
    @State private var pendingCommandID: UUID?
    @State private var commandSentAt = Date.distantPast
    init(model: LCAppModel, initialSource: LCFridaLogSource = .process, showsSourcePicker: Bool = true) {
        self.model = model
        self.showsSourcePicker = showsSourcePicker
        _source = State(initialValue: initialSource)
    }
    private var visibleSessions: [LCDebugSession] { sessions.filter { source.accepts($0.value) } }
    private var current: LCDebugSession? { visibleSessions.first { $0.id == selected } ?? visibleSessions.first }
    private var displayFile: URL? {
        source == .phone ? phoneFile : source == .process ? current?.console : (clients.first { $0.lastPathComponent == selectedClient } ?? clients.first)
    }
    private var phoneFile: URL? {
        guard let current, let first=LCPhoneScriptLog.descriptors(current.value).first,let name=first["file"] as? String else { return nil }
        return current.folder.appendingPathComponent("phone-scripts").appendingPathComponent(name)
    }
    private var root: URL? { (model.uiSelectedContainer ?? model.uiContainers.first)?.containerURL }
    private var activeSession: LCDebugSession? {
        guard source == .phone, model.isAppRunning, let root else { return nil }
        let records = IOSVMProcessRegistry.shared.records(forBundle: model.appInfo.relativeBundlePath)
            .compactMap { $0 as? [String:Any] }
            .filter { $0["state"] as? String == "running" && $0["container"] as? String == root.lastPathComponent }
        guard let record = records.max(by: { ($0["startedAt"] as? Double ?? 0) < ($1["startedAt"] as? Double ?? 0) }),
              let pid = record["pid"] as? Int else { return nil }
        let started = record["startedAt"] as? Double ?? 0
        return sessions.first { $0.pid == pid && ($0.value["startedAt"] as? Double ?? 0) >= started - 1 }
    }
    private var commandScripts: [[String:Any]] {
        guard let activeSession, LCPhoneScriptLog.supportsCommands(activeSession.value) else { return [] }
        return LCPhoneScriptLog.descriptors(activeSession.value)
    }
    private var commandScript: [String:Any]? {
        commandScripts.first { $0["id"] as? String == commandScriptID } ?? commandScripts.first
    }
    private var canClearCurrent: Bool { !model.isAppRunning && (source == .computer ? displayFile != nil : current != nil) }
    private var canClearAll: Bool { !model.isAppRunning && (!sessions.isEmpty || !clients.isEmpty) }
    var body: some View {
        List {
            Section {
                Text(model.displayName).font(.headline)
                Text(source.detail).font(.caption).foregroundStyle(.secondary)
                if showsSourcePicker {
                    Picker("日志来源", selection: $source) {
                        ForEach(LCFridaLogSource.allCases, id: \.self) { channel in Text(channel.title).tag(channel) }
                    }.pickerStyle(.segmented)
                }
                if source == .process {
                    Toggle("显示重复类警告", isOn: $showDuplicateWarnings)
                    if hiddenWarnings > 0 && !showDuplicateWarnings {
                        Text("当前内容已隐藏 \(hiddenWarnings) 条重复类警告，脚本和网络错误仍保留。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if source == .computer, !clients.isEmpty {
                    Picker("连接日志", selection: $selectedClient) {
                        Text("最新连接").tag("")
                        ForEach(clients, id: \.lastPathComponent) { Text(clientLabel($0)).tag($0.lastPathComponent) }
                    }
                }
                if source != .computer, !visibleSessions.isEmpty {
                    Picker("启动会话", selection: $selected) {
                        Text("最新一次").tag("")
                        ForEach(visibleSessions, id: \.id) { session in
                            let date = Date(timeIntervalSince1970: session.value["startedAt"] as? Double ?? 0)
                            Text(date.formatted(date: .abbreviated, time: .shortened) + " · PID " + String(session.pid) + ((session.value["frida"] as? [String:Any])?["automatic"] as? Bool == true ? " · 手机自动" : " · 进程")).tag(session.id)
                        }
                    }
                }
            }
            Section {
                TextField("查找日志内容", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    if !query.isEmpty { Button("清空搜索") { query = "" }.buttonStyle(.borderless) }
                    Spacer()
                    Button { paused.toggle(); if !paused { reload() } } label: {
                        Label(paused ? "继续刷新" : "暂停刷新", systemImage: paused ? "play.fill" : "pause.fill")
                    }.buttonStyle(.borderless)
                }.font(.caption)
            } footer: { if paused { Text("仅暂停列表刷新；执行命令会恢复刷新以接收结果。") } }
            if source == .phone, let activeSession {
                commandSection(activeSession)
            }
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
            if let notice { Section { Text(notice).foregroundStyle(.secondary) } }
            if displayFile == nil {
                LCToolEmptyState(title: "暂无" + source.title + "日志", message: source.emptyMessage, symbol: source.symbol)
            } else if text.isEmpty {
                Text(source == .phone ? "脚本尚无独立 console/send 输出；App 自身日志在进程控制台。" : (hiddenWarnings > 0 ? "当前内容仅有已隐藏的重复类警告。" : "该次启动尚无控制台输出，或未启用控制台记录。")).foregroundStyle(.secondary)
            } else {
                Section {
                    LCAnalysisTextContent(text: text, query: query, wraps: wraps).padding(.vertical, 6)
                } footer: { Text(source == .phone ? "这里只显示脚本的 console/send 与已捕获 JS 异常。每个脚本取末尾部分，合计最多 256 KiB；进程与 SDK 输出请切换到进程来源。原格式打包脚本及未捕获错误请查看进程控制台。" : source == .computer ? "页面按电脑脚本名称展示最后 256 KiB；导出保留带来源、PID 和会话标识的 JSONL。日志可能包含脚本主动打印的数据。" : "页面显示最后 256 KiB；精简导出会过滤重复类警告，原始导出保留全部内容。完整控制台每次最多 4 MiB，可能包含脚本主动打印的数据。") }
            }
        }
        .navigationTitle(showsSourcePicker ? source.title + "日志" : "lc.tools.logs".loc).navigationBarTitleDisplayMode(.inline)
        .modifier(LCAnalysisCopyFeedback(copied: $copied))
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if let displayFile, FileManager.default.fileExists(atPath: displayFile.path) {
                    Menu {
                        Button { UIPasteboard.general.string = text; copied = true } label: { Label("复制当前显示内容", systemImage: "doc.on.doc") }
                        Toggle("自动换行", isOn: $wraps)
                        Divider()
                        Button(source == .phone ? "导出脚本输出" : source == .process ? "导出精简日志" : "导出日志") { export(clean: source != .computer) }
                        if source != .computer { Button(source == .phone ? "导出结构化脚本记录" : "导出原始日志") { export(clean: false) } }
                    } label: { Image(systemName: "square.and.arrow.up") }
                }
                Menu {
                    Button("清空当前日志", role: .destructive) {
                        clearRequest = ClearRequest(source: source, all: false, session: current, clientFile: displayFile)
                    }.disabled(!canClearCurrent)
                    Button("清空此 App 全部调试日志", role: .destructive) {
                        clearRequest = ClearRequest(source: source, all: true, session: nil, clientFile: nil)
                    }.disabled(!canClearAll)
                } label: { Image(systemName: "trash") }
            }
        }
        .sheet(isPresented: $sharing, onDismiss: {
            if let exportFolder { LCManagedDirectory.cleanup(exportFolder) }
            exportURL = nil; exportFolder = nil
        }) { if let exportURL { ActivityViewController(activityItems: [exportURL]) } }
        .task { while !Task.isCancelled { if !paused || sendingCommand { reload() }; do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break } } }
        .onChange(of: selected) { _ in paused = false; reloadText() }
        .onChange(of: source) { _ in selected = ""; selectedClient = ""; notice = nil; reloadText() }
        .onChange(of: selectedClient) { _ in paused = false; reloadText() }
        .onChange(of: showDuplicateWarnings) { _ in reloadText() }
        .alert(item: $clearRequest) { request in
            Alert(
                title: Text(request.all ? "清空此 App 全部调试日志？" : "清空当前日志？"),
                message: Text(request.all ? "会删除此 App 全部手机启动会话、脚本输出和电脑回传日志。Frida 配置、脚本库和 App 沙盒数据不会删除。" : "只删除当前选择的日志，不删除 Frida 配置、脚本库或 App 沙盒数据。"),
                primaryButton: .destructive(Text("清空")) { clear(request) },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }
    private struct ClearRequest: Identifiable {
        let id = UUID()
        let source: LCFridaLogSource
        let all: Bool
        let session: LCDebugSession?
        let clientFile: URL?
    }
    private func clear(_ request: ClearRequest) {
        notice = nil; failure = nil
        guard !model.isAppRunning, let root else { failure = "关闭目标并选择数据容器后再清空日志。"; return }
        do {
            let removed: Int
            if request.all {
                removed = try LCFridaLogCleaner.clearAll(root: root)
            } else {
                switch request.source {
                case .phone, .process:
                    guard let session = request.session else { throw LCFridaScriptStore.failure("没有可清空的当前会话。") }
                    removed = try LCFridaLogCleaner.clearSession(root: root, folder: session.folder, source: request.source)
                case .computer:
                    guard let file = request.clientFile else { throw LCFridaScriptStore.failure("没有可清空的电脑日志。") }
                    removed = try LCFridaLogCleaner.clearComputerLog(root: root, file: file)
                }
            }
            selected = ""; selectedClient = ""; text = ""
            reload()
            notice = removed == 0 ? "没有需要清空的日志。" : "已清空 \(removed) 项调试日志。"
        } catch { failure = error.localizedDescription }
    }
    @ViewBuilder
    private func commandSection(_ session: LCDebugSession) -> some View {
        Section {
            if !LCPhoneScriptLog.supportsCommands(session.value) {
                Text("此会话由旧版创建，重新启动目标后可使用实时脚本命令。").font(.footnote).foregroundStyle(.secondary)
            } else if commandScripts.isEmpty {
                Text("当前会话没有独立脚本上下文。").font(.footnote).foregroundStyle(.secondary)
            } else {
                if commandScripts.count > 1 {
                    Picker("脚本", selection: $commandScriptID) {
                        ForEach(commandScripts.indices, id: \.self) { index in
                            let script = commandScripts[index]
                            Text(script["name"] as? String ?? "未命名脚本").tag(script["id"] as? String ?? "")
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("例如 1 + 1 或 console.log('probe')", text: $command)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(sendingCommand ? "等待执行" : "执行") { sendCommand(session) }
                        .disabled(sendingCommand || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commandScript == nil)
                }
            }
        } header: { Text("执行脚本命令") } footer: {
            Text("命令由目标进程中的 Frida 脚本上下文通过 Script.evaluate 实际执行，等同于电脑端 Frida 的 -e。console/send 输出进入下方日志。")
        }
    }
    private func sendCommand(_ session: LCDebugSession) {
        guard let script = commandScript, let id = script["id"] as? String else { return }
        do {
            let report = try LCFridaScriptCompatibility.inspect(command)
            if let syntaxError = report.syntaxError {
                throw LCFridaScriptStore.failure(syntaxError + "。请修正后再执行。")
            }
            let request = try LCPhoneScriptLog.sendCommand(folder: session.folder, session: session.value, scriptID: id, expression: command)
            paused = false
            sendingCommand = true
            pendingCommandID = request
            commandSentAt = Date()
            command = ""
            notice = "命令已发送，等待目标脚本执行。"
            failure = nil
        } catch {
            sendingCommand = false
            pendingCommandID = nil
            failure = error.localizedDescription
        }
    }
    private func clientLabel(_ url: URL) -> String {
        let pieces = url.deletingPathExtension().lastPathComponent.split(separator:"-")
        guard pieces.count >= 3, let milliseconds = Double(pieces[1]) else { return url.lastPathComponent }
        return Date(timeIntervalSince1970:milliseconds / 1000).formatted(date:.abbreviated,time:.shortened) + " · PID " + pieces[2]
    }
    private func reload() {
        if let root {
            sessions = LCDebugSession.list(root: root)
            let directory = root.appendingPathComponent("Library/iOSVM/Debug")
            if (try? LCFridaLogBoundary.directory(directory, inside: root)) != nil {
                clients = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("client-") && $0.pathExtension == "jsonl" }
                    .filter { (try? LCFridaLogBoundary.regularFile($0, inside: root)) != nil }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
            } else {
                clients = []
            }
        }
        reloadText()
    }
    private func reloadText() {
        text = ""; failure = nil; hiddenWarnings = 0
        if sendingCommand && Date().timeIntervalSince(commandSentAt) >= 10 {
            sendingCommand = false
            pendingCommandID = nil
            notice = "lc.tools.commandTimedOut".loc
        }
        if source == .phone {
            guard let current else { return }
            do {
                let entries=try LCPhoneScriptLog.entries(folder:current.folder,session:current.value)
                text=LCPhoneScriptLog.text(entries,multiple:LCPhoneScriptLog.descriptors(current.value).count > 1)
                if sendingCommand {
                    let expected = pendingCommandID?.uuidString.lowercased()
                    let terminal = entries.compactMap { $0["message"] as? [String: Any] }.last { message in
                        guard let commandID = message["commandID"] as? String,
                              let type = message["type"] as? String else { return false }
                        return commandID.lowercased() == expected && ["command-result", "error"].contains(type)
                    }
                    if let terminal {
                        sendingCommand = false
                        pendingCommandID = nil
                        notice = (terminal["type"] as? String == "error" ? "lc.tools.commandFailed" : "lc.tools.commandCompleted").loc
                    }
                }
            } catch { failure=error.localizedDescription }
            return
        }
        guard let displayFile, let root else { return }
        do {
            text = String(decoding: try LCFridaLogBoundary.readTail(displayFile, inside: root, limit: 262144), as: UTF8.self)
                .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            if source != .computer {
                let result = LCConsoleLogFilter.clean(text)
                hiddenWarnings = result.hiddenWarnings
                if !showDuplicateWarnings { text = result.text }
            } else { text = LCFridaComputerLogFormatter.text(text) }
        } catch { failure = error.localizedDescription }
    }
    private func export(clean: Bool) {
        guard let displayFile, let root else { return }
        var workspace: URL?
        do {
            if source == .phone, let current {
                let entries=try LCPhoneScriptLog.entries(folder:current.folder,session:current.value,limit:4*1024*1024)
                let content: String
                if clean { content=LCPhoneScriptLog.text(entries,multiple:LCPhoneScriptLog.descriptors(current.value).count > 1) }
                else { content=try entries.map { String(data:try JSONSerialization.data(withJSONObject:$0,options:[.sortedKeys]),encoding:.utf8)! }.joined(separator:"\n") }
                let folder=try LCManagedDirectory.temporaryWorkspace(); workspace=folder
                let name="phone-auto-" + current.id + (clean ? ".log" : "-records.jsonl")
                let url=folder.appendingPathComponent(name)
                try Data(content.utf8).write(to:url,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                exportFolder=folder;exportURL=url;sharing=true
                return
            }
            let limit = 16 * 1024 * 1024
            let data = try LCFridaLogBoundary.readData(displayFile, inside: root, maximumBytes: limit)
            let output = clean ? Data(LCConsoleLogFilter.clean(String(decoding: data, as: UTF8.self)).text.utf8) : data
            let folder = try LCManagedDirectory.temporaryWorkspace()
            workspace = folder
            let identity = source == .computer ? displayFile.deletingPathExtension().lastPathComponent : (current?.id ?? "unknown")
            let url = folder.appendingPathComponent(source.exportName(session: identity, raw: !clean && source != .computer))
            try output.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            exportFolder = folder; exportURL = url; sharing = true
        } catch {
            if let workspace { LCManagedDirectory.cleanup(workspace) }
            failure = error.localizedDescription
        }
    }
}

struct LCFridaVersionsView: View {
    @ObservedObject var model: LCAppModel
    @State private var versions: [LCFridaVersions.Version] = []
    @State private var selected = "builtin"
    @State private var busy = false
    @State private var importing = false
    @State private var downloading = false
    @State private var message: String?
    @State private var cleanupCandidates: [URL] = []
    @State private var confirmingCleanup = false
    var body: some View {
        Form {
            Section {
                Picker("Gadget 版本", selection: $selected) {
                    ForEach(versions) { version in Text(version.version + (version.builtin ? " · 内置" : " · 已保存")).tag(version.id) }
                }.disabled(busy || model.isAppRunning)
                Button("从 GitHub 按需下载") { downloading = true }.disabled(busy)
                Button("导入其他版本的 Gadget") { importing = true }.disabled(busy)
                Button("应用并重新签名") { Task { await apply() } }.disabled(busy || model.isAppRunning || versions.isEmpty)
                if busy { ProgressView("正在准备版本与签名…") }
            } footer: { Text("每个 App 单独选择版本。切换前关闭目标；原插件目录会保留。电脑端建议使用相同 Frida 版本。不同版本可能影响脚本 API、预插桩数据或系统兼容性，切换不保证所有 Hook 可用。") }
            Section {
                Text("自定义版本导入解压后的 iOS Gadget .dylib，支持含普通 arm64 的 Universal 文件；版本号由你标注，文件另做 SHA-256 校验。不会执行导入文件来识别版本。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("清理未使用调试目录…", role: .destructive, action: prepareCleanup)
                    .disabled(busy || model.isAppRunning)
            } footer: {
                Text("仅删除没有被任何 App、签名请求或配置事务引用的 iAppVM Gadget 副本；不会删除脚本库、数据容器或备份。")
            }
        }
        .navigationTitle("Gadget 版本").navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(isPresented: $downloading, onDismiss: reload) { NavigationView { LCFridaDownloadView() } }
        .sheet(isPresented: $importing, onDismiss: reload) { NavigationView { LCFridaImportVersionView() } }
        .confirmationDialog("清理未使用调试目录？", isPresented: $confirmingCleanup, titleVisibility: .visible) {
            Button("删除 \(cleanupCandidates.count) 个目录", role: .destructive, action: cleanupUnused)
            Button("取消", role: .cancel) { cleanupCandidates = [] }
        } message: {
            Text("这些目录没有被任何 App、签名请求或未完成配置事务引用。删除后不可恢复。")
        }
        .alert("Gadget 版本", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
    private func reload() {
        do {
            versions = try LCFridaVersions.versions()
            if let folder = LCFridaSetup.folder(for: model.appInfo) { selected = try LCFridaScriptStore.selection(folder: folder).gadgetID ?? "builtin" }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func apply() async {
        guard !model.isAppRunning, let version = versions.first(where: { $0.id == selected }) else { return }
        busy = true; defer { busy = false }
        do {
            if !version.builtin && !IOSVMDeviceSigning.configured {
                throw "电脑签名模式目前只能应用随宿主签名过的内置 Gadget。请先配置手机签名证书，再切换下载或手动导入的版本。"
            }
            if let folder = LCFridaSetup.folder(for: model.appInfo) {
                let current = try LCFridaScriptStore.selection(folder: folder)
                if current.gadgetID == version.id && current.gadgetVersion == version.version {
                    message = "当前已是 \(version.version)，无需重复复制或签名。"
                    return
                }
            }
            try await LCFridaSetup.switchVersion(version, app: model.appInfo)
            model.uiTweakFolder = model.appInfo.tweakFolder
            let shared = DataManager.shared.model
            if let folder = model.uiTweakFolder, !shared.tweakFolderNames.contains(folder) { shared.tweakFolderNames.append(folder) }
            if IOSVMDeviceSigning.configured { try await IOSVMDeviceSigning.sign(model.appInfo) }
            else { try LCFridaSetup.requestSigning(model.appInfo) }
            message = "版本已切换。原目录保留；请重新启动目标，并让电脑端 Frida 与此版本匹配。"
        } catch { message = error.localizedDescription }
    }
    private func prepareCleanup() {
        let shared = DataManager.shared.model
        let apps = shared.apps + shared.hiddenApps + shared.arm32EmuApps
        guard !apps.contains(where: { $0.isAppRunning }) else {
            message = "请先关闭所有测试 App 窗口，再清理调试目录。"
            return
        }
        if let enumerator = FileManager.default.enumerator(at: LCTestPresetStore.root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == "pending-apply.json" {
                message = "存在未完成的配置切换，请先在启动诊断中恢复。"
                return
            }
        }
        var referenced = Set(apps.compactMap { $0.appInfo.tweakFolder })
        let requests = LCPath.docPath.appendingPathComponent("iOSVM/SigningRequests")
        for file in (try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil)) ?? [] {
            guard file.pathExtension == "json",
                  let data = try? LCFridaLogBoundary.readData(file, inside: LCPath.docPath, maximumBytes: 262144),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folder = value["tweakFolder"] as? String, !folder.isEmpty else { continue }
            referenced.insert(folder)
        }
        do {
            cleanupCandidates = try LCFridaWorkspace.unusedFolders(
                bases: [LCPath.tweakPath, LCPath.lcGroupTweakPath],
                referenced: referenced
            )
            if cleanupCandidates.isEmpty {
                message = "没有发现可安全清理的未使用调试目录。"
            } else {
                confirmingCleanup = true
            }
        } catch {
            cleanupCandidates = []
            message = error.localizedDescription
        }
    }
    private func cleanupUnused() {
        let candidates = cleanupCandidates
        cleanupCandidates = []
        guard !candidates.isEmpty else { return }
        var removed = 0
        var failed = 0
        for url in candidates {
            if LCManagedDirectory.cleanup(url) { removed += 1 } else { failed += 1 }
        }
        message = failed == 0
            ? "已清理 \(removed) 个未使用调试目录。"
            : "已清理 \(removed) 个目录，\(failed) 个目录未能删除，请查看系统日志。"
    }
}

private struct LCFridaImportVersionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var version = ""
    @State private var picking = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("版本号") { TextField("例如 17.7.3", text: $version).textInputAutocapitalization(.never).autocorrectionDisabled() }
            Button("选择 iOS Gadget dylib 并导入") { picking = true }
        }
        .navigationTitle("导入 Gadget").navigationBarTitleDisplayMode(.inline)
        .betterFileImporter(isPresented: $picking, types: [.item], callback: { urls in
            do { if let url = urls.first { try LCFridaVersions.importFile(url, version: version); dismiss() } }
            catch { message = error.localizedDescription }
        }, onDismiss: { picking = false })
        .alert("导入失败", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
}
