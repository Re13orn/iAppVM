import SwiftUI
import UIKit

struct LCTLSIdentitiesView: View {
    @ObservedObject var model: LCAppModel
    @State private var containerID: String
    @State private var entries: [Entry] = []
    @State private var message: String?
    @State private var copied = false
    typealias Entry = LCTLSIdentityStore.Entry
    init(model: LCAppModel, initialContainer: String? = nil) {
        self.model = model
        _containerID = State(initialValue: initialContainer ?? model.uiSelectedContainer?.folderName ?? model.uiContainers.first?.folderName ?? "")
    }
    var body: some View {
        List {
            Section {
                LCAnalysisContext(title: model.displayName, detail: "mTLS 客户端身份 · PKCS#12 / Burp")
                Picker("数据容器", selection: $containerID) {
                    ForEach(model.uiContainers, id: \.folderName) { item in Text(item.name == item.folderName ? "沙盒 \((model.uiContainers.firstIndex(of: item) ?? 0) + 1)" : item.name).tag(item.folderName) }
                }
                Text("在网络配置开启身份捕获，重启目标并触发客户端认证。导出文件含私钥；密码按原文显示。最多保存 20 项 / 32 MiB，达到上限后可在文件浏览器管理 Network/TLSIdentities。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message { Text(message).foregroundStyle(.orange) }
            }
            if entries.isEmpty { LCToolEmptyState(title: "尚无捕获的身份", message: "只捕获当前目标导入的 PKCS#12 和认证时选用的身份。Secure Enclave 等不可导出密钥会记录失败原因。", symbol: "key.horizontal") }
            ForEach(entries) { item in
                Section {
                    LCPathDetail(title: "来源", path: item.value["source"] as? String == "pkcs12-import" ? "App 导入 PKCS#12" : "App 选择客户端身份")
                    if let host = item.value["host"] as? String, !host.isEmpty { LCPathDetail(title: "主机", path: host) }
                    if let fingerprint = item.value["certificateSHA256"] as? String, !fingerprint.isEmpty { LCPathDetail(title: "证书 SHA-256", path: fingerprint) }
                    if let file = item.file {
                        LCPathDetail(title: "PKCS#12 密码", path: item.value["password"] as? String ?? "")
                        Button("复制密码") { UIPasteboard.general.string = item.value["password"] as? String ?? ""; copied = true }
                        if #available(iOS 16.0, *) { ShareLink(item: file) { Label("导出 .p12 给 Burp", systemImage: "square.and.arrow.up") } }
                    } else { Text(item.value["error"] as? String ?? "身份文件缺失或不可读取。").foregroundStyle(.orange) }
                } header: { Text(item.available ? "可用身份" : "无法导出") }
            }
            Section {
                Text("Burp → Settings → Network → TLS → Client TLS certificates → Add，填写目标主机，选择 File (PKCS#12)，导入 .p12 并填写上述密码。服务端身份认证和 App 接受代理证书是两件事，必要时还需开启 Pinning 绕过。")
                    .font(.footnote).textSelection(.enabled)
            } header: { Text("在 Burp 中使用") }
        }
        .navigationTitle("客户端身份导出").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新捕获身份") }
        .task(id: containerID) { reload() }
        .modifier(LCAnalysisCopyFeedback(copied: $copied))
    }
    private func reload() {
        entries = []; message = nil
        guard let container = model.uiContainers.first(where: { $0.folderName == containerID }) else { return }
        let root = container.containerURL.appendingPathComponent("Library/iOSVM/Network/TLSIdentities")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            let result = try LCTLSIdentityStore.load(root: root, inside: container.containerURL)
            entries = result.entries
            message = result.message
        } catch { message = error.localizedDescription }
    }
}
