import SwiftUI
import UIKit

private struct LCNetworkEvent: Identifiable {
    let id: String
    let value: [String: Any]
    var url: String { value["url"] as? String ?? "" }
    var method: String { value["method"] as? String ?? "" }
    var layer: String { value["layer"] as? String ?? "" }
    var transport: String {
        if layer == "socket" { return "Socket 端点" }
        if layer == "proxy" { return "Socket 代理" }
        return url.hasPrefix("wss:") || url.hasPrefix("ws:") ? "WebSocket 连接" : "HTTP / HTTPS"
    }
    var failed: Bool {
        value["error"] != nil || value["state"] as? String == "proxyError" || (value["status"] as? Int ?? 0) >= 400
    }
    var tone: LCStatusTone {
        if value["error"] != nil || value["state"] as? String == "proxyError" { return .error }
        if let code = value["status"] as? Int {
            if code >= 400 { return .warning }
            if code >= 200 { return .success }
        }
        return .neutral
    }
    var duration: String? {
        guard let seconds = value["duration"] as? Double else { return nil }
        return seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }
    var host: String { URL(string: url)?.host ?? url }
    var displayHost: String {
        guard let address = URL(string: url), let host = address.host else { return url }
        guard let port = address.port else { return host }
        let formatted = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
        return formatted + ":" + String(port)
    }
    var path: String {
        if layer == "socket" || layer == "proxy" { return "" }
        guard let components = URLComponents(string: url), components.host != nil else { return "" }
        return (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath) + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
    var status: String {
        if let status = value["status"] as? Int { return String(status) }
        if value["error"] != nil { return "失败" }
        switch value["state"] as? String {
        case "tunnel": return "隧道已建立"
        case "proxyError": return "代理连接失败"
        case "created": return "已创建"
        case "complete": return "已结束"
        default: return value["state"] as? String ?? ""
        }
    }
}

struct LCNetworkView: View {
    @ObservedObject var model: LCAppModel
    @State private var settings = LCNetworkSettings()
    @State private var port = "8080"
    @State private var containerID = ""
    @State private var session = ""
    @State private var sessions: [URL] = []
    @State private var events: [LCNetworkEvent] = []
    @State private var eventsByID: [String: LCNetworkEvent] = [:]
    @State private var loadedLogPath = ""
    @State private var loadedLogOffset: UInt64 = 0
    @State private var partialLogLine = Data()
    @State private var filter = ""
    @State private var scope = "all"
    @State private var paused = false
    @State private var page = "traffic"
    @State private var message: String?
    @StateObject private var diagnostic = LCProxyDiagnostic()
    @State private var networkReceipt: [String: Any] = [:]
    @State private var runtimeLabel = "尚无启动回执"
    @State private var confirmingClear = false
    private var settingsURL: URL {
        IOSVMGuestAccess.networkSettingsDirectory(documents: LCPath.docPath)
            .appendingPathComponent(model.appInfo.relativeBundlePath + ".json")
    }
    private var container: LCContainer? {
        model.uiContainers.first { $0.folderName == containerID } ?? model.uiSelectedContainer ?? model.uiContainers.first
    }
    private var logRoot: URL? { container?.containerURL.appendingPathComponent("Library/iOSVM/Network") }
    private var selectedFile: URL? { sessions.first { $0.lastPathComponent == session } ?? sessions.first }
    private var filtered: [LCNetworkEvent] {
        let terms = filter.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return events.filter { event in
            let matchesScope = scope == "all" || (scope == "errors" && event.failed)
                || (scope == "http" && event.layer == "urlsession")
                || (scope == "socket" && ["socket", "proxy"].contains(event.layer))
            let searchable = [event.url, event.method, event.status, event.transport].joined(separator: " ")
            return matchesScope && terms.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.displayName).font(.subheadline.weight(.semibold))
                    Label(runtimeLabel, systemImage: "waveform.path.ecg")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 2)
            }
            Picker("网络工具", selection: $page) {
                Text("流量记录").tag("traffic")
                Text("捕获与代理").tag("settings")
            }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            Section {
                NavigationLink { LCTLSAnalysisView(model: model, containerID: container?.folderName) } label: {
                    Label("TLS 证书与认证分析", systemImage: "checkmark.seal")
                }
            }
            if page == "traffic" {
                trafficSection
                Section {
                    DisclosureGroup("捕获范围") {
                        Text("URLSession 请求与响应，以及部分 Socket 端点。WebView、自定义网络库等可能未被记录；列表为空不表示没有流量。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.font(.subheadline)
                }
            } else {
                proxySection
                verificationSection
                captureSection
                tlsSection
                Section {
                    Button(action: save) {
                        Text("保存配置").frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.borderedProminent).disabled(model.isAppRunning)
                } footer: {
                    Text(model.isAppRunning ? "请先关闭此 App 的测试窗口，再保存配置。" : "保存后重新启动目标 App 生效。")
                }
            }
        }
        .navigationTitle("网络分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    if page == "settings" { Button("保存", action: save).disabled(model.isAppRunning) }
                    if #available(iOS 16.0, *), let selectedFile {
                        ShareLink(item: selectedFile) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
        .onAppear {
            #if IOSVM_TESTING
            if UserDefaults.standard.bool(forKey: "iosvmTestNetworkSettings") { page = "settings" }
            #endif
            let existingURL = IOSVMGuestAccess.networkSettings(bundle: model.appInfo.relativeBundlePath, documents: LCPath.docPath)
            if let data = try? LCFridaLogBoundary.readData(existingURL, inside: LCPath.docPath, maximumBytes: 16384),
               let value = try? JSONDecoder().decode(LCNetworkSettings.self, from: data) {
                settings = value; port = String(value.port)
            }
            #if IOSVM_TESTING
            if UserDefaults.standard.bool(forKey: "iosvmTestSaveNetwork"), model.appInfo.relativeBundlePath == "dev.iosvm.storagecheck.app" {
                let requested = UserDefaults.standard.string(forKey: "iosvmTestProxyType") ?? "off"
                settings.capture = true; settings.bodies = false
                settings.proxyType = ["off", "http", "socks5"].contains(requested) ? requested : "off"
                settings.host = settings.proxyType == "off" ? "" : (UserDefaults.standard.string(forKey: "iosvmTestProxyHost") ?? "127.0.0.1")
                port = UserDefaults.standard.string(forKey: "iosvmTestProxyPort") ?? "8080"
                save() // Exercise the same validation, migration and save action as the button.
                let saved = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let output = LCPath.docPath.appendingPathComponent("iOSVMUITests")
                try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let report: [String: Any] = ["message": message ?? "", "capture": saved?["capture"] as? Bool ?? false, "proxyType": saved?["proxyType"] as? String ?? "missing", "path": settingsURL.path]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("network-ui-save.json"), options: .atomic)
                message = nil
            }
            #endif
        }
        .task {
            while !Task.isCancelled {
                if !paused { await reload() }
                reloadVerification()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
        .onDisappear { diagnostic.cancel() }
        .onChange(of: session) { _ in paused = false; Task { await reloadEvents() } }
        .onChange(of: containerID) { _ in paused = false; session = ""; Task { await reload() } }
        .confirmationDialog("清除此容器的捕获记录？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("删除 \(sessions.count) 个捕获会话", role: .destructive) { Task { await clear() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除此数据容器内的网络捕获记录，不修改代理配置、App 沙盒或其他容器的日志。")
        }
        .alert("网络工具", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }

    private var verificationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Text("目标运行配置").font(.caption).foregroundStyle(.secondary)
                Text(runtimeLabel).font(.subheadline)
            }
            if let sockets = networkReceipt["socketProxy"] as? [String: Any] {
                HStack { Text("已建立 Socket 隧道"); Spacer(); Text(String(sockets["opened"] as? Int ?? 0)).monospacedDigit() }
                HStack { Text("Socket 连接错误"); Spacer(); Text(String(sockets["failed"] as? Int ?? 0)).monospacedDigit() }
                if let code = sockets["lastError"] as? Int, code != 0 {
                    Text("最近错误：" + NSError(domain: NSPOSIXErrorDomain, code: code).localizedDescription).font(.caption).foregroundStyle(.secondary)
                }
            }
            if settings.proxyType != "off" {
                Button { diagnostic.test(kind: settings.proxyType, host: settings.host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 0) } label: {
                    Label(diagnostic.running ? "正在验证代理…" : "测试当前代理地址", systemImage: "network")
                }.disabled(diagnostic.running)
                Text(diagnostic.result).font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("生效与连通性") } footer: {
            Text("测试验证当前输入地址的代理握手，不修改配置。目标加载回执和隧道数量另列；HTTPS 证书信任与其他网络路径需单独验证。")
        }
    }
    private func reloadVerification() {
        networkReceipt = [:]; runtimeLabel = "尚无启动回执"
        guard let container else { return }
        let directory = container.containerURL.appendingPathComponent("Library/iOSVM/Network")
        guard (try? LCFridaLogBoundary.directory(directory, inside: container.containerURL)) != nil else { return }
        let file = directory.appendingPathComponent("status.json")
        guard let data = try? LCFridaLogBoundary.readData(file, inside: container.containerURL, maximumBytes: 65536),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        networkReceipt = value
        let records = IOSVMProcessRegistry.shared.records(forBundle: model.appInfo.relativeBundlePath).compactMap { $0 as? [String: Any] }.filter { $0["container"] as? String == container.folderName }
        let current = records.max { ($0["startedAt"] as? Double ?? 0) < ($1["startedAt"] as? Double ?? 0) }
        let existingURL = IOSVMGuestAccess.networkSettings(bundle: model.appInfo.relativeBundlePath, documents: LCPath.docPath)
        guard let saved = try? LCFridaLogBoundary.readData(existingURL, inside: LCPath.docPath, maximumBytes: 16384),
              value["settingsDigest"] as? String == LCFridaScriptStore.digest(saved) else {
            runtimeLabel = "保存的配置与回执不同，等待重新启动"; return
        }
        if (value["startedAt"] as? Double ?? 0) < (current?["startedAt"] as? Double ?? 0) - 1 { runtimeLabel = "等待本次进程回执"; networkReceipt = [:]; return }
        if value["configurationLoaded"] as? Bool != true { runtimeLabel = "尚未确认配置加载完成" }
        else if current?["pid"] as? Int == value["pid"] as? Int && current?["state"] as? String == "running" { runtimeLabel = "当前目标进程已加载保存配置" }
        else { runtimeLabel = "上次启动已加载；当前运行尚未确认" }
    }

    private var captureSection: some View {
        Section {
            Toggle("捕获网络请求", isOn: $settings.capture)
            Toggle("记录请求与响应正文", isOn: $settings.bodies).disabled(!settings.capture)
            DisclosureGroup("记录内容与限制") {
                Text("记录 URLSession 的地址、方法、请求头、响应头、状态码、耗时与错误。正文每侧最多 64 KiB；流式上传和下载文件不读取正文。按用户要求不做脱敏：认证头、Cookie 和密钥参数会按原文记录，正文可能包含敏感内容。")
                Text("另观察 connect/sendto 端点。WebView、自定义网络库、WebSocket 消息及 UDP 正文未覆盖。每次启动最多 2000 条事件 / 8 MiB，每个容器保留 10 次记录。")
            }.font(.footnote).foregroundStyle(.secondary)
        } header: { Text("流量捕获") } footer: {
            Text("配置仅应用于此 App，不是设备级全流量抓包。")
        }
    }
    private var tlsSection: some View {
        Section {
            Toggle("绕过服务端证书校验与 Pinning", isOn: $settings.tlsBypass)
            Toggle("捕获并导出 mTLS 身份", isOn: $settings.tlsIdentities)
            NavigationLink { LCTLSIdentitiesView(model: model, initialContainer: container?.folderName) } label: {
                Label("客户端身份与 Burp 导出", systemImage: "key.horizontal")
            }
            if let hit = networkReceipt["tlsLastHit"] as? String {
                LCPathDetail(title: "最近命中", path: hit)
            }
        } header: { Text("HTTPS 拦截测试") } footer: {
            Text("仅对当前 App 生效，重启后应用。绕过系统/URLSession 及部分常见库校验，不保证自定义 TLS。身份捕获会保存原始 PKCS#12、密码或可导出的客户端私钥打包结果；不可导出密钥会说明原因。")
        }
    }
    private var proxySection: some View {
        Section {
            Picker("代理类型", selection: $settings.proxyType) {
                Text("不覆盖 App 设置").tag("off")
                Text("HTTP CONNECT").tag("http")
                Text("SOCKS5").tag("socks5")
            }
            if settings.proxyType != "off" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("服务器").font(.caption).foregroundStyle(.secondary)
                    TextField("IP 或域名，例如 192.168.1.10", text: $settings.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                }.padding(.vertical, 4)
                HStack {
                    Text("端口")
                    TextField("8080", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            }
            DisclosureGroup("代理支持范围") {
                Text("iOS 17+：配置 URLSession、WebKit 和 Network.framework 默认上下文，并转发 Guest 模块通过 connect 建立的 TCP（含 Flutter/Dart）。代理失败时关闭隧道，不回落直连。系统内部、自定义系统调用等路径仍不保证覆盖。")
                Text("支持无认证 HTTP CONNECT / SOCKS5。被接管的外部 UDP/QUIC 会拒绝；本机回环连接保留。未开启 HTTPS 绕过时保留原证书校验；开启后按已覆盖策略干预。Socket 隧道不提供 HTTPS 正文解密。手机的 127.0.0.1 指向手机自身。")
            }.font(.footnote).foregroundStyle(.secondary)
        } header: { Text("此 App 的代理") }
    }
    private var trafficSection: some View {
        Section {
            if !model.uiContainers.isEmpty {
                Picker("数据容器", selection: $containerID) {
                    Text("当前容器").tag("")
                    ForEach(model.uiContainers, id: \.folderName) { Text($0.name == $0.folderName ? "沙盒 " + String(model.uiContainers.firstIndex(of: $0).map { $0 + 1 } ?? 1) : $0.name).tag($0.folderName) }
                }
            }
            if !sessions.isEmpty {
                Picker("捕获会话", selection: $session) {
                    Text("最新").tag("")
                    ForEach(sessions, id: \.lastPathComponent) { url in
                        Text(sessionTitle(url)).tag(url.lastPathComponent)
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索域名、路径、方法、状态", text: $filter)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary).accessibilityLabel("清空搜索").buttonStyle(.borderless)
                    }
                }
                Picker("筛选流量", selection: $scope) {
                    Text("全部").tag("all")
                    Text("HTTP").tag("http")
                    Text("Socket").tag("socket")
                    Text("异常").tag("errors")
                }.pickerStyle(.segmented)
                HStack {
                    Text("\(filtered.count) / \(events.count) 项").monospacedDigit()
                    Spacer()
                    Button {
                        paused.toggle()
                        if !paused { Task { await reload() } }
                    } label: {
                        Label(paused ? "继续刷新" : "暂停刷新", systemImage: paused ? "play.fill" : "pause.fill")
                    }.buttonStyle(.borderless)
                }.font(.caption).foregroundStyle(.secondary)
                if paused {
                    Label("列表已暂停，目标仍继续捕获", systemImage: "pause.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(filtered) { event in
                    NavigationLink { LCNetworkEventView(event: event) } label: {
                        LCNetworkEventRow(event: event)
                    }
                    .contextMenu {
                        Button { UIPasteboard.general.string = event.url } label: { Label("复制 URL / 端点", systemImage: "doc.on.doc") }
                        Button { filter = event.host } label: { Label("筛选此主机", systemImage: "line.3.horizontal.decrease.circle") }
                    }
                }
                if filtered.isEmpty {
                    LCToolEmptyState(title: events.isEmpty ? "暂未观察到请求" : "没有匹配的请求", message: events.isEmpty ? "在目标 App 内产生请求后回到这里。未覆盖的网络路径仍可能有流量。" : "调整搜索词或切换流量筛选。", symbol: "network")
                    if !events.isEmpty { Button("清除筛选") { filter = ""; scope = "all" } }
                }
                Button("清除此容器的捕获记录", role: .destructive) { confirmingClear = true }.disabled(model.isAppRunning)
            } else {
                LCToolEmptyState(title: "还没有流量记录", message: "启用捕获并保存后，重新启动目标 App，再回到这里查看请求。", symbol: "network")
                Button("设置捕获与代理") { page = "settings" }
            }
        } header: { Text("捕获记录 · \(events.count) 项") }
    }

    private func sessionTitle(_ url: URL) -> String {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count > 1, let milliseconds = Double(parts[1]) else { return url.lastPathComponent }
        let formatter = DateFormatter()
        formatter.dateStyle = .short; formatter.timeStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    private func save() {
        guard !model.isAppRunning else { return }
        settings.host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.proxyType == "off" || (!settings.host.isEmpty && !settings.host.contains("://") && !settings.host.contains("/") && settings.host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil && Int(port).map { (1...65535).contains($0) } == true) else {
            message = "请输入服务器 IP / 域名和 1–65535 的端口，不要填写 URL。"; return
        }
        settings.port = Int(port) ?? 8080
        do {
            try LCManagedDirectory.migrateLegacy(LCPath.docPath.appendingPathComponent("iOSVM/NetworkSettings"), to: settingsURL.deletingLastPathComponent(), inside: LCPath.docPath)
            try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            message = "已保存，请重新启动 \(model.displayName)。"
        } catch { message = error.localizedDescription }
    }
    private func reload() async {
        guard let container, let logRoot,
              (try? LCFridaLogBoundary.directory(logRoot, inside: container.containerURL)) != nil else {
            sessions = []
            resetEventCache()
            return
        }
        sessions = ((try? FileManager.default.contentsOfDirectory(at: logRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("traffic-") && $0.pathExtension == "jsonl" }
            .filter { (try? LCFridaLogBoundary.regularFile($0, inside: container.containerURL)) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        await reloadEvents()
    }
    private func reloadEvents() async {
        guard let container, let file = selectedFile else { resetEventCache(); return }
        if loadedLogPath != file.path {
            resetEventCache()
            loadedLogPath = file.path
        }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 0 else {
            resetEventCache()
            return
        }
        if UInt64(size) < loadedLogOffset {
            resetEventCache()
            loadedLogPath = file.path
        }
        guard UInt64(size) > loadedLogOffset else { return }
        let path = file.path
        let offset = loadedLogOffset
        let limit = min(1024 * 1024, size - Int(offset))
        let priorPartial = partialLogLine
        let containerURL = container.containerURL
        // Parse the chunk off the main thread: a 1 MiB slice of JSONL can
        // block the UI for tens of milliseconds every poll.
        let parsed = await Task.detached(priority: .utility) { () -> (Data, UInt64, [(String, [String: Any])]) in
            guard let chunk = try? LCFridaLogBoundary.readRange(URL(fileURLWithPath: path), inside: containerURL, offset: offset, limit: limit)
            else { return (priorPartial, offset, []) }
            var combined = priorPartial
            combined.append(chunk)
            let lines = combined.split(separator: 10, omittingEmptySubsequences: false)
            let hasTrailingNewline = combined.last == 10
            let completeCount = max(0, lines.count - 1)
            var parsed: [(String, [String: Any])] = []
            for line in lines.prefix(completeCount) where !line.isEmpty {
                if let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   let id = value["id"] as? String, value["layer"] as? String != "session", value["layer"] as? String != "tls" {
                    parsed.append((id, value))
                }
            }
            let remainder: Data
            if hasTrailingNewline { remainder = Data() }
            else if let last = lines.last { remainder = Data(last) }
            else { remainder = Data() }
            return (remainder, offset + UInt64(chunk.count), parsed)
        }.value
        // A session/container switch may have reset the cache while we were
        // parsing; only apply the result if the target file is unchanged.
        guard loadedLogPath == path, selectedFile?.path == path, self.container?.folderName == container.folderName, !paused else { return }
        partialLogLine = parsed.0
        loadedLogOffset = parsed.1
        for (id, value) in parsed.2 {
            eventsByID[id] = LCNetworkEvent(id: id, value: value)
        }
        events = eventsByID.values.sorted { ($0.value["time"] as? Double ?? 0) > ($1.value["time"] as? Double ?? 0) }
    }
    private func resetEventCache() {
        events = []
        eventsByID = [:]
        loadedLogPath = ""
        loadedLogOffset = 0
        partialLogLine = Data()
    }
    private func clear() async {
        guard !model.isAppRunning else { return }
        guard let container else { return }
        do {
            for file in sessions {
                _ = try LCFridaLogBoundary.regularFile(file, inside: container.containerURL)
                try FileManager.default.removeItem(at: file)
            }
            session = ""
            resetEventCache()
            await reload()
        }
        catch { message = error.localizedDescription }
    }
}

private struct LCNetworkEventRow: View {
    let event: LCNetworkEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.method.isEmpty ? event.transport : event.method)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 4)
                if let duration = event.duration {
                    Text(duration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(event.status).font(.caption.weight(.semibold)).foregroundStyle(event.tone.color)
            }
            Text(event.displayHost).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            if !event.path.isEmpty {
                Text(event.path).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct LCNetworkEventView: View {
    let event: LCNetworkEvent
    @State private var page = "request"
    @State private var query = ""
    @State private var copied = false
    private var metadata: String {
        var value = event.value
        value.removeValue(forKey: "requestBodyBase64"); value.removeValue(forKey: "responseBodyBase64")
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    private func copy(_ text: String) { UIPasteboard.general.string = text; copied = true }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(event.method.isEmpty ? event.transport : event.method)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        Spacer()
                        LCStatusTag(text: event.status, tone: event.tone)
                    }
                    Text(event.displayHost).font(.headline).textSelection(.enabled)
                    if let duration = event.duration {
                        Label(duration, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = event.value["error"] as? String {
                        Text(error).font(.subheadline).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.padding(.vertical, 5)
            }
            Picker("详情内容", selection: $page) {
                Text("请求").tag("request")
                Text("响应").tag("response")
                Text("原始事件").tag("raw")
            }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            if page == "raw" {
                Section {
                    LCNetworkTextBlock(title: "事件 JSON（正文单独展示）", text: metadata, query: query, onCopy: copy)
                }
            } else {
                if page == "request" {
                    Section("地址") {
                        if matches(event.url) { copyRow("URL / 端点", event.url) }
                        if let components = URLComponents(string: event.url), let items = components.queryItems, !items.isEmpty {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                if matches(item.name + " " + (item.value ?? "")) { copyRow(item.name, item.value ?? "（无值）", copyValue: item.value ?? "") }
                            }
                        }
                    }
                } else if let url = event.value["responseURL"] as? String, url != event.url {
                    Section("响应地址") { if matches(url) { copyRow("重定向后的 URL", url) } }
                }
                headersSection
                bodySection
            }
        }
        .navigationTitle("流量详情")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索参数、头或正文")
        .toolbar {
            Menu {
                Button { copy(event.url) } label: { Label("复制 URL / 端点", systemImage: "link") }
                Button { copy(metadata) } label: { Label("复制事件 JSON", systemImage: "curlybraces") }
            } label: { Image(systemName: "doc.on.doc") }
            .accessibilityLabel("复制流量信息")
        }
        .overlay(alignment: .bottom) {
            if copied {
                Label("已复制", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium)).padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 20)
                    .allowsHitTesting(false)
            }
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 1_500_000_000); copied = false } catch {}
        }
    }

    private func copyRow(_ title: String, _ text: String, copyValue: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LCPathDetail(title: title, path: text).frame(maxWidth: .infinity, alignment: .leading)
            Button { copy(copyValue ?? text) } label: {
                Image(systemName: "doc.on.doc").frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.borderless).accessibilityLabel("复制 " + title)
        }
    }

    private var headersSection: some View {
        let key = page == "request" ? "requestHeaders" : "responseHeaders"
        let headers = event.value[key] as? [String: Any] ?? [:]
        let names = headers.keys.sorted().filter { matches($0 + " " + String(describing: headers[$0]!)) }
        return Section {
            ForEach(names, id: \.self) { name in copyRow(name, String(describing: headers[name]!)) }
            if headers.isEmpty {
                Text("此事件未记录" + (page == "request" ? "请求头" : "响应头"))
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if names.isEmpty {
                Text("没有匹配的头字段").font(.subheadline).foregroundStyle(.secondary)
            }
        } header: { Text((page == "request" ? "请求头" : "响应头") + " · \(headers.count)") }
    }

    private var bodySection: some View {
        let prefix = page == "request" ? "request" : "response"
        let data = (event.value[prefix + "BodyBase64"] as? String).flatMap { Data(base64Encoded: $0) }
        return Section {
            if let data {
                LCNetworkBodyView(data: data, query: query, onCopy: copy).id(prefix)
                if event.value[prefix + "BodyTruncated"] as? Bool == true {
                    Label("正文已截断，仅展示捕获的部分", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text(event.value[prefix + "BodyUnavailable"] as? String ?? "此事件没有捕获正文。可能未开启正文记录、请求尚未完成，或该网络路径不支持。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } header: { Text(page == "request" ? "请求正文" : "响应正文") }
    }
}

private struct LCNetworkBodyView: View {
    let data: Data
    let query: String
    let onCopy: (String) -> Void
    @State private var formatted = true
    private var raw: String { String(data: data, encoding: .utf8) ?? data.base64EncodedString() }
    private var json: String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if json != nil {
                    Toggle("格式化 JSON", isOn: $formatted).font(.caption)
                        .toggleStyle(.button).buttonStyle(.bordered)
                }
            }
            LCNetworkTextBlock(title: String(data: data, encoding: .utf8) == nil ? "Base64 · 二进制正文" : "正文", text: formatted ? (json ?? raw) : raw, query: query, onCopy: onCopy)
            if formatted && json != nil {
                Button("复制原文") { onCopy(raw) }.font(.caption).buttonStyle(.borderless)
            }
        }.padding(.vertical, 4)
    }
}

private struct LCNetworkTextBlock: View {
    let title: String
    let text: String
    let query: String
    let onCopy: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { onCopy(text) } label: { Label("复制", systemImage: "doc.on.doc") }
                    .font(.caption).buttonStyle(.borderless)
            }
            if !query.isEmpty && !text.localizedCaseInsensitiveContains(query) {
                Text("此内容未匹配搜索词").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    Text(text.isEmpty ? "（空正文）" : text)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false).padding(12)
                }
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }.padding(.vertical, 4)
    }
}
