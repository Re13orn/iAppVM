import SwiftUI

struct LCFridaDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var releases = LCFridaDownload.presets
    @State private var version = "17.7.3"
    @State private var custom = false
    @State private var customVersion = ""
    private var requestedVersion: String { custom ? customVersion.trimmingCharacters(in: .whitespacesAndNewlines) : version }
    @State private var busy = false
    @State private var refreshing = false
    @State private var status = ""
    @State private var fraction: Double?
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        Form {
            Section {
                Toggle("手动指定版本号", isOn: $custom).disabled(busy)
                if custom {
                    TextField("例如 16.7.19", text: $customVersion)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                } else {
                    Picker("官方版本", selection: $version) {
                        ForEach(releases, id: \.self) { Text($0).tag($0) }
                    }.disabled(busy)
                }
                Button(refreshing ? "正在获取…" : "刷新 GitHub 近期版本") { refresh() }.disabled(busy || refreshing)
                if LCFridaDownload.valid(requestedVersion) {
                    Link("查看 GitHub 官方发布页", destination: LCFridaDownload.page(requestedVersion))
                    if #available(iOS 16.0, *) {
                        ShareLink(item: LCFridaDownload.assetURL(requestedVersion)) { Label("分享下载链接", systemImage: "link") }
                    } else {
                        Button("复制下载链接") { UIPasteboard.general.url = LCFridaDownload.assetURL(requestedVersion) }
                    }
                }
            } header: { Text("frida/frida 官方发布") } footer: {
                Text("预置常用版本入口，可刷新近期版本或输入完整版本号。只下载 iOS Universal Gadget；其他版本仍需实际验证兼容性。")
            }
            Section {
                if busy {
                    if let fraction { ProgressView(value: fraction) } else { ProgressView() }
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                    Button("取消下载", role: .cancel) { task?.cancel() }
                } else {
                    Button("下载到版本库") { download() }
                        .disabled(!LCFridaDownload.valid(requestedVersion) || refreshing)
                }
            } footer: {
                Text("按需下载，不增加安装包体积。完成后自动校验 SHA-256、解压 XZ 并检查 arm64 动态库；再返回版本页选择应用与签名。下载不会更改任何 App 当前使用的版本。")
            }
        }
        .navigationTitle("下载 Gadget").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        .onDisappear { task?.cancel() }
        .alert("Gadget 下载", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
    private func refresh() {
        refreshing = true
        task = Task {
            defer { refreshing = false }
            do {
                let recent = try await LCFridaDownload.recent()
                try Task.checkCancellation()
                var seen = Set<String>()
                releases = (recent + releases + [version]).filter { seen.insert($0).inserted }
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    private func download() {
        let requested = requestedVersion
        busy = true; fraction = nil; status = "正在获取官方资源信息…"
        task = Task {
            defer { busy = false }
            do {
                if try LCFridaVersions.versions().contains(where: { $0.version == requested }) {
                    message = "版本库已有 \(requested)，可返回直接选择。"; return
                }
                try await LCFridaDownload.download(requested) { received, total in
                    await MainActor.run {
                        fraction = total > 0 ? min(1, Double(received) / Double(total)) : nil
                        status = String(format: "已下载 %.1f MiB%@", Double(received) / 1048576,
                                        total > 0 ? String(format: " / %.1f MiB", Double(total) / 1048576) : "")
                        if received == total { status = "下载完成，正在校验与解压…" }
                    }
                }
                message = "\(requested) 已加入版本库。返回版本页后可选择应用。"
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}
