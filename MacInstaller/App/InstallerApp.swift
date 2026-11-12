import SwiftUI
import AppKit

struct Phone: Identifiable {
    let id: String
    let name: String
    let version: String
    let paired: Bool
}

@MainActor final class InstallerModel: ObservableObject {
    @Published var phones: [Phone] = []
    @Published var selected = ""
    @Published var email = ""
    @Published var password = ""
    @Published var anisette = "https://ani.iloader.app"
    @Published var busy = false
    @Published var scanning = false
    @Published var progress = 0.0
    @Published var stage = ""
    @Published var message = "连接 iPhone，开始安装与配置。"
    @Published var error: String?
    @Published var completed = false
    @Published var prompt: [String: Any]?
    @Published var promptID = ""
    @Published var code = ""
    @Published var team = ""
    @Published var certificate = ""
    @Published var openApp = false
    private var process: Process?
    private var input: FileHandle?
    private var generation = UUID()
    private var buffer = Data()
    private var succeeded = false

    var ready: Bool { !busy && phones.contains { $0.id == selected && $0.paired } && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty }
    var payload: String { Bundle.main.resourceURL!.appendingPathComponent("iAppVM.app").path }
    var build: String {
        (NSDictionary(contentsOfFile: payload + "/Info.plist")?["CFBundleVersion"] as? String) ?? "未知"
    }
    func refresh() {
        guard !busy else { return }
        scanning = true
        start(["command": "devices"])
    }
    func install() {
        guard ready else { return }
        error = nil; completed = false; openApp = false; progress = 0; stage = "login"
        busy = true
        let request: [String: Any] = ["command": "install", "udid": selected, "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
                                      "password": password, "payload": payload, "anisette": anisette]
        start(request)
        password = ""
    }
    func start(_ request: [String: Any]) {
        process?.terminate()
        generation = UUID(); let current = generation
        buffer = Data(); succeeded = false
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/iappvm-installer-engine")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            error = "安装组件缺失，请重新下载完整安装助手。"; busy = false; scanning = false; return
        }
        let task = Process(); let stdin = Pipe(); let stdout = Pipe()
        task.executableURL = executable
        task.standardInput = stdin; task.standardOutput = stdout
        // Do not persist authentication or upstream diagnostics.
        task.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "RUST_LOG"); environment.removeValue(forKey: "RUST_BACKTRACE")
        task.environment = environment
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.accept(data)
            }
        }
        task.terminationHandler = { [weak self] task in
            // Readability events queued on the main actor may follow the exit event.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.generation == current else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                self.scanning = false
                if self.busy && !self.succeeded && self.error == nil {
                    self.error = "安装组件已退出（\(task.terminationStatus)），请重新连接手机后重试。"
                }
                self.busy = false; self.prompt = nil; self.input = nil; self.process = nil
            }
        }
        do {
            try task.run(); process = task; input = stdin.fileHandleForWriting
            try send(request)
        } catch {
            task.terminate(); self.error = "无法启动安装组件：" + error.localizedDescription; busy = false; scanning = false
        }
    }
    func accept(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { cancel(); error = "安装组件返回了异常数据，请重新打开安装助手。"; return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let event = value["event"] as? String else { continue }
            switch event {
            case "devices":
                let old = selected
                phones = (value["devices"] as? [[String: Any]] ?? []).compactMap { p in
                    guard let id = p["udid"] as? String else { return nil }
                    return Phone(id: id, name: p["name"] as? String ?? "iPhone", version: p["version"] as? String ?? "", paired: p["paired"] as? Bool ?? false)
                }
                selected = phones.contains { $0.id == old } ? old : (phones.first?.id ?? "")
                scanning = false; succeeded = true
            case "progress":
                message = value["message"] as? String ?? "正在处理…"
                stage = value["stage"] as? String ?? ""
                progress = value["progress"] as? Double ?? progress
            case "prompt":
                promptID = value["id"] as? String ?? ""; code = ""; team = ""
                certificate = ((value["data"] as? [String: Any])?["certificates"] as? [[String: Any]])?.first?["fingerprint"] as? String ?? ""
                prompt = value
            case "open_app":
                openApp = true; message = value["message"] as? String ?? "请打开 iAppVM"; progress = 0.9
            case "complete":
                succeeded = true; completed = true; busy = false; openApp = false; progress = 1
                message = value["message"] as? String ?? "安装完成"; stage = "complete"
            case "error":
                error = value["message"] as? String ?? "安装失败"; busy = false; scanning = false; openApp = false; prompt = nil
            default: break
            }
        }
    }
    private func send(_ value: [String: Any]) throws {
        guard let input else { throw CocoaError(.fileWriteUnknown) }
        var bytes = try JSONSerialization.data(withJSONObject: value); bytes.append(10)
        try input.write(contentsOf: bytes)
        bytes.resetBytes(in: 0..<bytes.count)
    }
    func answer(_ fields: [String: Any]) {
        var reply = fields; reply["id"] = promptID
        do { try send(reply); prompt = nil; code = "" }
        catch { self.error = "无法提交验证，请重新开始。"; cancel() }
    }
    func cancel() {
        generation = UUID(); process?.terminate(); process = nil
        try? input?.close(); input = nil
        busy = false; scanning = false; prompt = nil; openApp = false; password = ""; code = ""
        message = "操作已停止。已安装的内容可能保留，请重新开始以确认配置结果。"
    }
}

#if !INSTALLER_MODEL_TEST
@main struct InstallerApp: App {
    @StateObject private var model = InstallerModel()
    var body: some Scene {
        WindowGroup("iAppVM 安装助手") { InstallerView(model: model) }
            .defaultSize(width: 860, height: 690)
            .windowResizability(.contentMinSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

#endif

struct InstallerView: View {
    @ObservedObject var model: InstallerModel
    @State private var advanced = false
    private let steps = [("login", "登录 Apple 账号"), ("provision", "准备签名与描述文件"), ("sign", "签名应用与独立窗口"), ("install", "安装到 iPhone"), ("configure", "配置并验证手机签名")]
    private var current: Int { steps.firstIndex { $0.0 == model.stage } ?? (model.completed ? 5 : -1) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "iphone.and.arrow.forward").font(.system(size: 34, weight: .medium)).foregroundStyle(.blue).padding(.bottom, 22)
                Text("iAppVM").font(.system(size: 29, weight: .semibold))
                Text("安装助手").font(.title3).foregroundStyle(.secondary).padding(.top, 3)
                Text("连接一次，完成安装与配置。")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 20)
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 10) {
                            Image(systemName: index < current || model.completed ? "checkmark.circle.fill" : (index == current && model.busy ? "circle.inset.filled" : "circle"))
                                .foregroundStyle(index <= current || model.completed ? Color.blue : Color.secondary.opacity(0.5))
                            Text(step.1).font(.callout).foregroundStyle(index == current ? .primary : .secondary)
                        }
                    }
                }.padding(.top, 38)
                Spacer()
                Text("iOS 构建 \(model.build)\nmacOS 安装助手 0.1")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(30).frame(width: 265, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.completed ? "准备好了" : "安装到你的 iPhone").font(.system(size: 24, weight: .semibold))
                        Text(model.completed ? "手机签名自检已通过，可以开始导入 IPA。" : "使用你自己的 Apple 账号，无需准备证书文件。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("目标设备", systemImage: "iphone").font(.headline)
                                Spacer()
                                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                                    .help("重新检测 USB 设备").disabled(model.busy || model.scanning)
                            }
                            if model.scanning {
                                HStack { ProgressView().controlSize(.small); Text("正在检测设备…").foregroundStyle(.secondary) }
                            } else if model.phones.isEmpty {
                                Text("用 USB 连接手机，解锁后点击“信任此电脑”，然后刷新。")
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            } else {
                                Picker("设备", selection: $model.selected) {
                                    ForEach(model.phones) { p in Text("\(p.name) · iOS \(p.version)").tag(p.id) }
                                }.labelsHidden().disabled(model.busy)
                                if model.phones.first(where: { $0.id == model.selected })?.paired == false {
                                    Text("尚未配对：请解锁手机、信任此电脑，再点击刷新。")
                                        .font(.callout).foregroundStyle(.orange)
                                }
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.completed {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Apple 账号").font(.headline)
                            TextField("Apple 账号（邮箱或手机号）", text: $model.email).textContentType(.username)
                            SecureField("密码", text: $model.password).textContentType(.password)
                            Text("密码仅用于本次登录，不会保存。签名私钥保存在本机和手机钥匙串。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.textFieldStyle(.roundedBorder).disabled(model.busy)
                        DisclosureGroup("连接设置", isExpanded: $advanced) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("认证辅助服务").font(.caption)
                                TextField("HTTPS 地址", text: $model.anisette).textFieldStyle(.roundedBorder)
                                Text("默认连接 ani.iloader.app 获取 Apple 登录所需的设备认证数据。账号登录请求发往 Apple；此服务不是 Apple 官方服务。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.padding(.top, 8)
                        }.font(.callout).disabled(model.busy)
                    }
                    if model.busy || model.completed {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(value: model.progress)
                            Text(model.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                            if model.openApp {
                                Text("手机：设置 → 通用 → VPN 与设备管理 → 信任开发者，然后打开或重新打开 iAppVM。若系统要求启用开发者模式或重启，请按提示操作。")
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if let error = model.error {
                        Label { Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                            icon: { Image(systemName: "exclamationmark.circle") }
                            .font(.callout).foregroundStyle(.red)
                    }
                    HStack {
                        if model.busy {
                            Button("停止") { model.cancel() }
                        } else if model.completed {
                            Button("完成") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderedProminent)
                        } else {
                            Button("安装并配置") { model.install() }.buttonStyle(.borderedProminent)
                                .disabled(!model.ready).keyboardShortcut(.defaultAction)
                        }
                        Spacer()
                    }
                    if !model.completed {
                        Text("以后续签也使用此助手。系统要求的信任、验证码及开发者模式确认，需要你在设备上完成。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(30)
            }.frame(minWidth: 475)
        }
        .frame(minWidth: 800, minHeight: 650)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancel() }
        .sheet(isPresented: Binding(get: { model.prompt != nil }, set: { if !$0 && model.prompt != nil { model.cancel() } })) {
            PromptView(model: model)
        }
    }
}

struct PromptView: View {
    @ObservedObject var model: InstallerModel
    var data: [String: Any] { model.prompt?["data"] as? [String: Any] ?? [:] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.prompt?["kind"] as? String == "team" {
                Text("选择开发团队").font(.title2.bold())
                Picker("团队", selection: $model.team) {
                    Text("请选择").tag("")
                    ForEach(data["teams"] as? [[String: Any]] ?? [], id: \.description) { t in
                        Text("\(t["name"] as? String ?? "个人团队") · \(t["id"] as? String ?? "")").tag(t["id"] as? String ?? "")
                    }
                }
                HStack { Button("取消") { model.cancel() }; Spacer(); Button("继续") { model.answer(["team": model.team]) }.disabled(model.team.isEmpty) }
            } else if model.prompt?["kind"] as? String == "reuse_certificate" {
                Text("复用已有开发证书").font(.title2.bold())
                Text("找到与此 Apple 团队匹配的本机签名身份。复用后无需占用新的证书名额。")
                    .fixedSize(horizontal: false, vertical: true)
                Picker("签名身份", selection: $model.certificate) {
                    ForEach(data["certificates"] as? [[String: Any]] ?? [], id: \.description) { c in
                        Text(c["name"] as? String ?? "Apple Development").tag(c["fingerprint"] as? String ?? "")
                    }
                }
                Text("签名身份会保存在助手和手机钥匙串，用于安装及手机内 IPA 签名。macOS 可能要求你允许读取选中的私钥。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("取消") { model.cancel() }; Spacer()
                    Button("复用并继续") { model.answer(["fingerprint": model.certificate]) }
                        .buttonStyle(.borderedProminent).disabled(model.certificate.isEmpty)
                }
            } else {
                Text("验证 Apple 账号").font(.title2.bold())
                Text(data["sms"] as? Bool == true ? "请输入短信中的六位验证码。" : "请在受信任设备上允许登录，然后输入六位验证码。")
                if let last = data["lastError"] as? String, !last.isEmpty { Text(last).font(.callout).foregroundStyle(.orange) }
                TextField("六位验证码", text: $model.code).textFieldStyle(.roundedBorder)
                    .onChange(of: model.code) { _, value in model.code = String(value.filter(\.isNumber).prefix(6)) }
                HStack {
                    Button("重新发送") { model.answer(["action": "resend"]) }
                    Button("发送到设备") { model.answer(["action": "devices"]) }
                    Menu("发送短信") {
                        ForEach(data["numbers"] as? [[String: Any]] ?? [], id: \.description) { n in
                            Button(n["numberWithDialCode"] as? String ?? "受信任号码") {
                                model.answer(["action": "sms", "number": n["id"] ?? 0])
                            }
                        }
                    }
                }.font(.callout)
                HStack {
                    Button("取消") { model.cancel() }; Spacer()
                    Button("验证") { model.answer(["action": "code", "code": model.code]) }
                        .buttonStyle(.borderedProminent).disabled(model.code.count != 6).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(28).frame(width: 430)
    }
}
