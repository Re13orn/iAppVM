import SwiftUI

struct LCTestingRuntimeView: View {
    let root: URL
    let isRunning: () -> Bool
    @State private var configuration = ""
    @State private var message: String?
    private var configurationURL: URL { root.appendingPathComponent("iOSVMLaunch.json") }
    private let sample = """
    {
      "version": 1,
      "arguments": [],
      "environment": {},
      "workingDirectory": "Documents",
      "captureConsole": false
    }
    """

    var body: some View {
        Form {
            Section {
                // JSON needs literal punctuation, just like JavaScript. Share
                // the plain code editor with smart quotes/dashes disabled.
                LCCodeEditor(text: $configuration)
                    .frame(minHeight: 240)
                Button("保存并用于下次启动", action: save)
                Button("恢复默认启动方式", role: .destructive, action: reset)
            } header: { Text("lc.tools.launchParameters".loc) } footer: {
                Text("保存后启用会话记录。arguments 是传给目标的参数；工作目录须已存在于此容器。HOME、LC_*、DYLD_* 等由容器管理。恢复默认会移除配置并保留历史日志。")
            }
        }
        .navigationTitle("lc.tools.launchParameters".loc)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { reload() } label: { Image(systemName: "arrow.clockwise") } }
        .onAppear(perform: reload)
        .alert("测试配置", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func reload() {
        configuration = (try? String(contentsOf: configurationURL, encoding: .utf8)) ?? sample
    }
    private func save() {
        guard !isRunning() else { message = "请先停止使用此容器的目标，再保存启动配置。"; return }
        let data = Data(configuration.utf8)
        if let error = LCSharedUtils.validateTestingConfiguration(data, root: root.path) { message = error; return }
        do {
            try data.write(to: configurationURL, options: .atomic)
            message = "已保存，下次启动时生效。"
        } catch { message = error.localizedDescription }
    }
    private func reset() {
        guard !isRunning() else { message = "请先停止使用此容器的目标。"; return }
        do {
            if FileManager.default.fileExists(atPath: configurationURL.path) { try FileManager.default.removeItem(at: configurationURL) }
            configuration = sample
            message = "已恢复默认启动方式，历史日志已保留。"
        } catch { message = error.localizedDescription }
    }
}
