import SwiftUI
import UIKit

private enum LCUnifiedLogSource: String, CaseIterable, Identifiable {
    case all = "全部"
    case phone = "手机脚本"
    case computer = "电脑脚本"
    case process = "进程"
    case network = "网络"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: return "rectangle.stack"
        case .phone: return "iphone"
        case .computer: return "desktopcomputer"
        case .process: return "terminal"
        case .network: return "network"
        }
    }
    var color: Color {
        switch self {
        case .all: return .secondary
        case .phone, .process, .network: return .accentColor
        case .computer: return .secondary
        }
    }
}

private struct LCUnifiedLogEvent: Identifiable {
    let id: String
    let time: Double
    let source: LCUnifiedLogSource
    let session: String
    let text: String
    var problem = false
    var estimatedTime = false
}

struct LCUnifiedLogsView: View {
    @ObservedObject var model: LCAppModel
    private let showsSourcePicker: Bool
    init(model: LCAppModel, networkOnly: Bool = false, showsSourcePicker: Bool = true) {
        self.model = model
        self.showsSourcePicker = showsSourcePicker
        _source = State(initialValue: networkOnly ? .network : .all)
    }
    @State private var events: [LCUnifiedLogEvent] = []
    @State private var source: LCUnifiedLogSource = .all
    @State private var query = ""
    @State private var paused = false
    @State private var selectedSession = ""
    @State private var problemsOnly = false
    @State private var copied = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var confirmingClear = false
    @State private var exportURL: URL?
    @State private var exportFolder: URL?
    @State private var sharing = false

    private var root: URL? {
        (model.uiSelectedContainer ?? model.uiContainers.first)?.containerURL
    }
    private var visible: [LCUnifiedLogEvent] {
        events.filter {
            (source == .all || $0.source == source)
                && (selectedSession.isEmpty || $0.session == selectedSession)
                && (!problemsOnly || $0.problem)
                && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
                    || $0.session.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            Section {
                LCAnalysisContext(title: model.displayName, detail: "当前数据容器 · 最新事件在上")
                if showsSourcePicker {
                    Picker("来源", selection: $source) {
                        ForEach(LCUnifiedLogSource.allCases) { item in Label(item.rawValue, systemImage: item.symbol).tag(item) }
                    }
                }
                Picker("会话", selection: $selectedSession) {
                    Text("全部会话").tag("")
                    ForEach(Array(Set(events.filter { source == .all || $0.source == source }.map(\.session))).sorted().reversed(), id: \.self) { session in
                        Text(sessionLabel(session)).tag(session)
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索日志、脚本、URL 或会话", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("清空搜索")
                    }
                }
                Toggle("仅看异常事件", isOn: $problemsOnly)
                HStack {
                    Text("\(visible.count) / \(events.count) 条").monospacedDigit()
                    Spacer()
                    Button { paused.toggle(); if !paused { reload() } } label: {
                        Label(paused ? "继续刷新" : "暂停刷新", systemImage: paused ? "play.fill" : "pause.fill")
                    }.buttonStyle(.borderless)
                }.font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text(paused ? "仅暂停列表刷新，目标仍继续记录。" : "最近 2000 条；≈ 为近似会话时间。异常筛选依据结构化错误/警告，普通进程文本未分级。")
            }

            if let failure {
                Section { Text(failure).foregroundStyle(.red) }
            }
            if let notice {
                Section { Text(notice).foregroundStyle(.secondary) }
            }
            if visible.isEmpty {
                LCToolEmptyState(
                    title: events.isEmpty ? "暂无日志" : "没有匹配事件",
                    message: events.isEmpty ? "启动目标并产生脚本、网络或控制台输出后再查看。" : "调整来源或搜索条件。",
                    symbol: "text.magnifyingglass"
                )
                if !events.isEmpty { Button("清除筛选") { query = ""; selectedSession = ""; problemsOnly = false } }
            } else {
                Section {
                    ForEach(visible) { event in
                        NavigationLink { LCUnifiedLogDetailView(event: event) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: event.source.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(event.source.color)
                                .frame(width: 28, height: 28)
                                .background(event.source.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(event.source.rawValue).font(.caption.weight(.semibold))
                                    if event.problem { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                                    Spacer()
                                    Text((event.estimatedTime ? "≈ " : "") + Date(timeIntervalSince1970: event.time).formatted(date: .omitted, time: .standard))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(event.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(4)
                                Text(event.session)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 5)
                        }
                        .contextMenu {
                            Button { UIPasteboard.general.string = event.text; copied = true } label: { Label("复制事件", systemImage: "doc.on.doc") }
                            Button { selectedSession = event.session } label: { Label("只看此会话", systemImage: "line.3.horizontal.decrease.circle") }
                        }
                    }
                } header: {
                    Text("时间轴 · 最新在上")
                }
            }
        }
        .navigationTitle("lc.tools.logs".loc)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(LCAnalysisCopyFeedback(copied: $copied))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        copyVisible()
                    } label: {
                        Label("复制当前筛选", systemImage: "doc.on.doc")
                    }
                    .disabled(visible.isEmpty)
                    Button {
                        export()
                    } label: {
                        Label("导出日志", systemImage: "square.and.arrow.up")
                    }
                    .disabled(visible.isEmpty)
                    Divider()
                    Button("清空当前容器日志", role: .destructive) {
                        confirmingClear = true
                    }
                    .disabled(model.isAppRunning || events.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if !paused { reload() }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
        .onChange(of: source) { _ in if !paused { reload() } }
        .confirmationDialog("清空当前容器日志？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空手机、电脑、进程和网络日志", role: .destructive, action: clearAll)
            Button("取消", role: .cancel) {}
        } message: {
            Text("必须关闭目标 App。脚本、插件、配置和沙盒业务文件不会删除。")
        }
        .sheet(isPresented: $sharing, onDismiss: cleanupExport) {
            if let exportURL { ActivityViewController(activityItems: [exportURL]) }
        }
        .onDisappear(perform: cleanupExport)
    }

    private func sessionLabel(_ name: String) -> String {
        let pieces = name.split(separator: "-")
        guard pieces.count > 1, let milliseconds = Double(pieces[1]) else { return name }
        let date = Date(timeIntervalSince1970: milliseconds / 1000).formatted(date: .abbreviated, time: .standard)
        return date + (name.hasPrefix("traffic-") ? " · 网络" : name.hasPrefix("client-") ? " · 电脑" : " · 启动")
    }

    private func reload() {
        failure = nil
        notice = nil
        guard let root else {
            events = []
            return
        }
        do {
            let sessions = LCDebugSession.list(root: root)
            var result: [LCUnifiedLogEvent] = []
            var unreadablePhoneSessions = 0
            for session in sessions where source != .network {
                let started = session.value["startedAt"] as? Double ?? 0
                let phoneEntries: [[String: Any]]
                do {
                    phoneEntries = try LCPhoneScriptLog.entries(folder: session.folder, session: session.value, limit: 256 * 1024)
                } catch {
                    // One broken script log must not hide readable process or network events.
                    unreadablePhoneSessions += 1
                    phoneEntries = []
                }
                for entry in phoneEntries {
                    let time = entry["time"] as? Double ?? started
                    let text = LCPhoneScriptLog.text([entry], multiple: true)
                    guard !text.isEmpty else { continue }
                    result.append(.init(
                        id: session.id + "-phone-" + String(format: "%.6f", time) + "-" + String(text.hashValue),
                        time: time,
                        source: .phone,
                        session: session.id,
                        text: text,
                        problem: ["error", "warn", "warning"].contains((entry["level"] as? String ?? entry["type"] as? String ?? "").lowercased())
                    ))
                }
                if let data = try? LCFridaLogBoundary.readTail(session.console, inside: root, limit: 128 * 1024) {
                    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
                    for (index, line) in lines.enumerated().suffix(300) {
                        result.append(.init(
                            id: session.id + "-process-" + String(index),
                            time: started + Double(index) / 10_000,
                            source: .process,
                            session: session.id,
                            text: String(line),
                            estimatedTime: true
                        ))
                    }
                }
            }

            let debugRoot = root.appendingPathComponent("Library/iOSVM/Debug")
            if (try? LCFridaLogBoundary.directory(debugRoot, inside: root)) != nil {
                let files = (try? FileManager.default.contentsOfDirectory(at: debugRoot, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.lastPathComponent.hasPrefix("client-") && file.pathExtension == "jsonl" {
                    guard let data = try? LCFridaLogBoundary.readTail(file, inside: root, limit: 128 * 1024) else { continue }
                    for (index, line) in String(decoding: data, as: UTF8.self).split(separator: "\n").enumerated() {
                        let value = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                        let text = (try? JSONSerialization.data(withJSONObject: value ?? ["raw": String(line)], options: [.sortedKeys]))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? String(line)
                        result.append(.init(
                            id: file.lastPathComponent + "-computer-" + String(index),
                            time: value?["time"] as? Double ?? Date().timeIntervalSince1970,
                            source: .computer,
                            session: file.lastPathComponent,
                            text: LCFridaComputerLogFormatter.text(text),
                            problem: Self.clientProblem(value),
                            estimatedTime: value?["time"] as? Double == nil
                        ))
                    }
                }
            }

            let networkRoot = root.appendingPathComponent("Library/iOSVM/Network")
            if (try? LCFridaLogBoundary.directory(networkRoot, inside: root)) != nil {
                let files = (try? FileManager.default.contentsOfDirectory(at: networkRoot, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.lastPathComponent.hasPrefix("traffic-") && file.pathExtension == "jsonl" {
                    guard let data = try? LCFridaLogBoundary.readTail(file, inside: root, limit: 256 * 1024) else { continue }
                    for (index, line) in String(decoding: data, as: UTF8.self).split(separator: "\n").enumerated() {
                        guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              value["layer"] as? String != "session" else { continue }
                        let method = value["method"] as? String ?? value["layer"] as? String ?? "NET"
                        let status: String
                        if let rawStatus = value["status"] {
                            status = String(describing: rawStatus)
                        } else {
                            status = value["state"] as? String ?? value["error"] as? String ?? ""
                        }
                        let url = value["url"] as? String ?? value["endpoint"] as? String ?? "未知端点"
                        result.append(.init(
                            id: file.lastPathComponent + "-network-" + String(index),
                            time: value["time"] as? Double ?? Date().timeIntervalSince1970,
                            source: .network,
                            session: file.lastPathComponent,
                            text: ([method, status, url, value["error"] as? String ?? ""].filter { !$0.isEmpty }).joined(separator: " "),
                            problem: value["error"] != nil || value["state"] as? String == "proxyError" || (value["status"] as? Int ?? 0) >= 400,
                            estimatedTime: value["time"] as? Double == nil
                        ))
                    }
                }
            }
            if unreadablePhoneSessions > 0 {
                notice = "\(unreadablePhoneSessions) 个会话的手机脚本日志无法读取；其余来源仍正常展示。"
            }
            let latest = Array(result.sorted { $0.time < $1.time }.suffix(2000))
            events = Array(latest.reversed())
        } catch {
            failure = error.localizedDescription
        }
    }

    // Only structured error/warning fields qualify; unstructured stdout is not guessed.
    private static func clientProblem(_ value: [String: Any]?) -> Bool {
        let message = value?["message"] as? [String: Any]
        let nested = message?["message"] as? [String: Any] ?? message
        return ["error", "warn", "warning"].contains((nested?["level"] as? String ?? nested?["type"] as? String ?? "").lowercased())
    }

    private func copyVisible() {
        UIPasteboard.general.string = exportText()
        copied = true
    }

    private func export() {
        do {
            let folder = try LCManagedDirectory.temporaryWorkspace()
            cleanupExport()
            let file = folder.appendingPathComponent("iAppVM-unified.log")
            try Data(exportText().utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            exportFolder = folder
            exportURL = file
            sharing = true
        } catch {
            failure = error.localizedDescription
        }
    }

    private func exportText() -> String {
        visible.map { event in
            let date = Date(timeIntervalSince1970: event.time).formatted(date: .numeric, time: .standard)
            return "[\(event.estimatedTime ? "≈ " : "")\(date)] [\(event.source.rawValue)] [\(event.session)] \(event.text)"
        }.joined(separator: "\n")
    }

    private func clearAll() {
        guard !model.isAppRunning, let root else { return }
        do {
            var removed = try LCFridaLogCleaner.clearAll(root: root)
            let networkRoot = root.appendingPathComponent("Library/iOSVM/Network")
            if (try? LCFridaLogBoundary.directory(networkRoot, inside: root)) != nil {
                for file in try FileManager.default.contentsOfDirectory(at: networkRoot, includingPropertiesForKeys: nil)
                    where file.lastPathComponent.hasPrefix("traffic-") && file.pathExtension == "jsonl" {
                    _ = try LCFridaLogBoundary.regularFile(file, inside: root)
                    try FileManager.default.removeItem(at: file)
                    removed += 1
                }
            }
            events = []
            notice = removed == 0 ? "没有需要清空的日志。" : "已清空 \(removed) 项日志。"
        } catch {
            failure = error.localizedDescription
        }
    }

    private func cleanupExport() {
        if let exportFolder { LCManagedDirectory.cleanup(exportFolder) }
        exportFolder = nil
        exportURL = nil
    }
}


/// Single log destination. Source-specific readers retain commands, history and raw exports.
struct LCAppLogsView: View {
    enum Source: String, CaseIterable, Identifiable {
        case all, phone, computer, process, network
        var id: String { rawValue }
        var title: String { ("lc.tools.logSource." + rawValue).loc }
    }
    @ObservedObject var model: LCAppModel
    @State private var source: Source

    init(model: LCAppModel, initialSource: Source = .all) {
        self.model = model
        _source = State(initialValue: initialSource)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("lc.tools.logSource".loc)
                Spacer()
                Picker("lc.tools.logSource".loc, selection: $source) {
                    ForEach(Source.allCases) { item in Text(item.title).tag(item) }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            reader.id(source)
        }
        .navigationTitle("lc.tools.logs".loc)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var reader: some View {
        switch source {
        case .all: LCUnifiedLogsView(model: model, showsSourcePicker: false)
        case .network: LCUnifiedLogsView(model: model, networkOnly: true, showsSourcePicker: false)
        case .phone: LCFridaLogsView(model: model, initialSource: .phone, showsSourcePicker: false)
        case .computer: LCFridaLogsView(model: model, initialSource: .computer, showsSourcePicker: false)
        case .process: LCFridaLogsView(model: model, initialSource: .process, showsSourcePicker: false)
        }
    }
}

private struct LCUnifiedLogDetailView: View {
    let event: LCUnifiedLogEvent
    @State private var query = ""
    @State private var wraps = true
    @State private var copied = false
    var body: some View {
        List {
            Section {
                LCAnalysisContext(title: event.source.rawValue, detail: Date(timeIntervalSince1970: event.time).formatted(date: .numeric, time: .standard) + (event.estimatedTime ? " · 近似会话时间" : ""))
                LCPathDetail(title: "会话", path: event.session)
            }
            Section {
                LCAnalysisTextContent(text: event.text, query: query, wraps: wraps).padding(.vertical, 6)
            } header: { Text("完整事件") }
        }
        .navigationTitle("日志详情").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "查找事件内容")
        .toolbar {
            Menu {
                Button { UIPasteboard.general.string = event.text; copied = true } label: { Label("复制完整事件", systemImage: "doc.on.doc") }
                Button { UIPasteboard.general.string = event.session; copied = true } label: { Label("复制会话标识", systemImage: "number") }
                Toggle("自动换行", isOn: $wraps)
            } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("日志操作")
        }
        .modifier(LCAnalysisCopyFeedback(copied: $copied))
    }
}
