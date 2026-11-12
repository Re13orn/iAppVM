import SwiftUI
import UIKit

private struct LCTLSEvent: Identifiable {
    let id: String
    let value: [String: Any]
    let file: String
    var host: String { value["host"] as? String ?? "未知主机" }
    var method: String { value["method"] as? String ?? "" }
    var client: Bool { method.contains("ClientCertificate") }
    var time: Double { value["time"] as? Double ?? 0 }
    var title: String {
        if value["testingOverride"] as? Bool == true { return "测试工具接受服务端证书" }
        if value["state"] as? String == "challenge" { return client ? "服务器请求客户端证书" : "服务器信任挑战" }
        switch value["disposition"] as? String {
        case "useCredential": return value["credentialKind"] as? String == "clientIdentity" ? "App 选择客户端身份" : "App 提供认证凭据"
        case "cancelAuthenticationChallenge": return "App 取消认证"
        case "rejectProtectionSpace": return "App 拒绝认证空间"
        case "performDefaultHandling": return "App 交给系统处理"
        default: return "认证处置记录"
        }
    }
}

struct LCTLSAnalysisView: View {
    @ObservedObject var model: LCAppModel
    @State private var containerID: String
    @State private var page = "static"
    @State private var query = ""
    @State private var clientOnly = false
    @State private var report: LCTLSAnalysis.Report?
    @State private var scanning = false
    @State private var scanError: String?
    @State private var events: [LCTLSEvent] = []
    @State private var readErrors = 0
    @State private var revision = UUID()
    init(model: LCAppModel, containerID: String? = nil) {
        self.model = model
        _containerID = State(initialValue: containerID ?? model.uiSelectedContainer?.folderName ?? model.uiContainers.first?.folderName ?? "")
    }
    private var container: LCContainer? { model.uiContainers.first { $0.folderName == containerID } }
    private var findings: [LCTLSFinding] {
        (report?.findings ?? []).filter { query.isEmpty || ($0.title + " " + $0.path + " " + $0.kind + " " + $0.detail + " " + ($0.certificate?.sha256 ?? "") + " " + ($0.certificate?.spkiSHA256 ?? "")).localizedCaseInsensitiveContains(query) }
    }
    private var visibleEvents: [LCTLSEvent] {
        events.filter { (!clientOnly || $0.client) && (query.isEmpty || ($0.host + " " + $0.title + " " + $0.file).localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        List {
            Section {
                LCAnalysisContext(title: model.displayName, detail: "证书与 Pinning 配置线索 · 系统 TLS 认证证据")
                Picker("分析来源", selection: $page) {
                    Text("证书与配置").tag("static")
                    Text("运行记录").tag("runtime")
                }.pickerStyle(.segmented)
            }
            Section {
                NavigationLink { LCTLSIdentitiesView(model: model, initialContainer: containerID) } label: {
                    Label("客户端身份与 Burp 导出", systemImage: "key.horizontal")
                }
            }
            if page == "static" { staticSections } else { runtimeSections }
        }
        .navigationTitle("TLS 认证分析").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: page == "static" ? "搜索域名、证书、路径或指纹" : "搜索主机、事件或会话")
        .toolbar {
            Button { revision = UUID() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(scanning).accessibilityLabel("重新分析证书与配置")
        }
        .task(id: revision) { await scan() }
        .task(id: containerID) {
            while !Task.isCancelled {
                reloadEvents()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
    }
    @ViewBuilder private var staticSections: some View {
        Section {
            if scanning { ProgressView("正在分析包内资源…") }
            if let scanError { Text(scanError).foregroundStyle(.red) }
            if let report {
                Text("\(report.findings.count) 个发现 · 检查 \(report.inspected) 个文件").font(.caption.monospacedDigit())
                if report.skipped > 0 || report.limited {
                    Label("跳过 \(report.skipped) 项" + (report.limited ? " · 已达到扫描上限" : ""), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
        } footer: {
            Text("证书存在不代表被使用；配置声明不代表运行时已执行。PKCS#12 仅列候选，不解锁或导出私钥。")
        }
        if report != nil && findings.isEmpty && !scanning {
            LCToolEmptyState(title: query.isEmpty ? "没有发现可识别的静态线索" : "没有匹配的发现", message: "不代表没有 Pinning 或 mTLS。代码内置、加密、运行时下发及自定义网络栈需要进一步分析。", symbol: "doc.text.magnifyingglass")
        }
        ForEach(findings) { finding in
            NavigationLink { LCTLSFindingView(finding: finding) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(kindTitle(finding.kind)).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                    Text(finding.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(finding.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                }.padding(.vertical, 4)
            }
        }
        Section {
            DisclosureGroup("覆盖范围与分析原理") {
                Text("解析 X.509 PEM/DER 公共证书、证书 SHA-256 与完整 SPKI 的 SHA-256；读取 plist/JSON 中的系统及 TrustKit 配置。排除签名目录和 mobileprovision，不跟随符号链接。")
                Text("最多遍历 20000 项、读取 32 MiB、单文件 2 MiB、保留 1000 个发现。普通小资源可按内容识别无证书扩展名的文件；不扫描全部大二进制中的内嵌数据、不解密资源。")
            }.font(.footnote).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var runtimeSections: some View {
        Section {
            Picker("数据容器", selection: $containerID) {
                ForEach(model.uiContainers, id: \.folderName) { item in
                    Text(item.name == item.folderName ? "沙盒 " + String((model.uiContainers.firstIndex(of: item) ?? 0) + 1) : item.name).tag(item.folderName)
                }
            }
            Toggle("仅看客户端证书认证", isOn: $clientOnly)
            Text("\(visibleEvents.count) / \(events.count) 条 · 最近的认证事件").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if readErrors > 0 { Text("\(readErrors) 个记录无法读取，其余记录仍展示。").font(.caption).foregroundStyle(.orange) }
        } footer: {
            Text("开启网络捕获并重启目标后记录。仅观察 App 已实现的 URLSession 认证回调，保留原回调选择与结果；系统默认路径、WebKit 和自定义 TLS 库可能没有记录。")
        }
        if visibleEvents.isEmpty {
            LCToolEmptyState(title: "尚未观察到认证事件", message: "触发相应连接后查看。没有记录不代表没有 TLS、Pinning 或 mTLS。", symbol: "network")
        }
        ForEach(visibleEvents) { event in
            NavigationLink { LCTLSEventView(event: event, findings: report?.findings ?? []) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(event.client ? "客户端身份" : "服务器信任").font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                        Spacer()
                        Text(Date(timeIntervalSince1970: event.time).formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(event.host).font(.subheadline.weight(.semibold))
                    Text(event.title).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
        }
        Section {
            Text("服务器信任挑战不等于 Pinning；App 选择身份不等于服务器已接受。会话级回调不强行归属某条请求；最终连接结果需结合流量记录。与网络捕获共用 2000 条事件 / 8 MiB 上限；仅记录服务器叶证书，不主动构建或验证证书链。读取最近 10 次捕获的各末尾 1 MiB，最多展示 500 条。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    @MainActor private func scan() async {
        scanning = true; scanError = nil
        let bundle = URL(fileURLWithPath: model.appInfo.bundlePath())
        let worker = Task.detached(priority: .utility) { try LCTLSAnalysis.scan(bundle: bundle, cancelled: { Task.isCancelled }) }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }; report = result
        } catch is CancellationError { } catch { scanError = error.localizedDescription }
        scanning = false
    }
    private func reloadEvents() {
        events = []; readErrors = 0
        guard let container else { return }
        let folder = container.containerURL.appendingPathComponent("Library/iOSVM/Network")
        guard (try? LCFridaLogBoundary.directory(folder, inside: container.containerURL)) != nil else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("traffic-") && $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(10)
        var result: [LCTLSEvent] = []
        for file in files {
            guard let data = try? LCFridaLogBoundary.readTail(file, inside: container.containerURL, limit: 1024 * 1024) else { readErrors += 1; continue }
            for line in data.split(separator: 10) {
                guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], value["layer"] as? String == "tls", let id = value["id"] as? String else { continue }
                result.append(.init(id: file.lastPathComponent + ":" + id, value: value, file: file.lastPathComponent))
            }
        }
        events = Array(result.sorted { $0.time > $1.time }.prefix(500))
    }
    private func kindTitle(_ kind: String) -> String {
        ["certificate": "包内公共证书", "ats-pinning": "系统 Pinning 声明", "pin-config-candidate": "Pinning 配置候选", "library-config": "第三方绑定配置线索", "identity-candidate": "客户端身份材料候选"][kind] ?? kind
    }
}

private struct LCTLSFindingView: View {
    let finding: LCTLSFinding
    @State private var copied = false
    var body: some View {
        List {
            Section {
                LCPathDetail(title: "资源路径", path: finding.path)
                Text(finding.detail).font(.subheadline).textSelection(.enabled)
            }
            if let certificate = finding.certificate { LCTLSCertificateSection(certificate: certificate) }
        }
        .navigationTitle(finding.certificate == nil ? "配置证据" : "证书详情").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                UIPasteboard.general.string = [finding.path, finding.title, finding.detail, finding.certificate?.sha256 ?? "", finding.certificate?.spkiSHA256 ?? ""].joined(separator: "\n"); copied = true
            } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制分析证据")
        }
        .modifier(LCAnalysisCopyFeedback(copied: $copied))
    }
}

private struct LCTLSCertificateSection: View {
    let certificate: LCTLSCertificate
    var body: some View {
        Section {
            LCPathDetail(title: "主题", path: certificate.subject)
            LCPathDetail(title: "签发者 CN", path: certificate.issuer)
            if let before = certificate.notBefore { LCPathDetail(title: "生效时间", path: before.formatted(date: .numeric, time: .standard)) }
            if let after = certificate.notAfter { LCPathDetail(title: "到期时间", path: after.formatted(date: .numeric, time: .standard)) }
            LCPathDetail(title: "证书 DER · SHA-256", path: certificate.sha256)
            if let spki = certificate.spkiSHA256 { LCPathDetail(title: "SPKI-SHA256-BASE64", path: spki) }
        } header: { Text("已解析的 X.509 公共证书") }
    }
}

private struct LCTLSEventView: View {
    let event: LCTLSEvent
    let findings: [LCTLSFinding]
    @State private var copied = false
    private var raw: String {
        String(data: (try? JSONSerialization.data(withJSONObject: event.value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data(), encoding: .utf8) ?? ""
    }
    private var certificates: [[String: Any]] {
        (event.value["serverCertificates"] as? [[String: Any]] ?? []) + ((event.value["clientCertificate"] as? [String: Any]).map { [$0] } ?? [])
    }
    var body: some View {
        List {
            Section {
                LCAnalysisContext(title: event.host, detail: event.title)
                LCPathDetail(title: "认证类型", path: event.method)
                LCPathDetail(title: "回调范围", path: event.value["scope"] as? String ?? "未知")
                LCPathDetail(title: "记录文件", path: event.file)
                if let request = event.value["requestID"] as? String { LCPathDetail(title: "关联请求 ID", path: request) }
                Text("这是认证回调证据，不单独证明 Pinning，也不证明客户端身份被服务器接受。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(certificates.enumerated()), id: \.offset) { _, value in
                if let encoded = value["derBase64"] as? String, let der = Data(base64Encoded: encoded), let certificate = LCTLSCertificate(der: der) {
                    LCTLSCertificateSection(certificate: certificate)
                    let matches = findings.filter { $0.certificate?.sha256 == certificate.sha256 }
                    if !matches.isEmpty {
                        Section {
                            Text("与以下包内证书相同；相同不代表参与 Pinning 校验。").font(.footnote).foregroundStyle(.secondary)
                            ForEach(matches) { finding in LCPathDetail(title: "包内路径", path: finding.path) }
                        }
                    }
                } else {
                    Section { LCPathDetail(title: value["subject"] as? String ?? "证书", path: value["sha256"] as? String ?? "未记录 DER") }
                }
            }
            Section { DisclosureGroup("原始事件与处置调用栈") { LCAnalysisTextContent(text: raw) } }
        }
        .navigationTitle("TLS 事件详情").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { UIPasteboard.general.string = raw; copied = true } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制 TLS 事件") }
        .modifier(LCAnalysisCopyFeedback(copied: $copied))
    }
}
