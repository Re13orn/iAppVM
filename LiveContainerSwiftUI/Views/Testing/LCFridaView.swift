import SwiftUI
import UIKit

struct LCFridaView: View {
    @ObservedObject var model: LCAppModel
    @State private var installed = false
    @State private var scriptPage = "phone"
    @State private var choseInitialPage = false
    @State private var wait = false
    @State private var busy = false
    @State private var port = 27042
    @State private var message: String?
    @State private var signingPending = false
    @State private var signingError: String?
    @State private var automatic = false
    @State private var gadgetVersion = "尚未记录"
    @State private var gadgetLoad = "尚无启动回执"
    @State private var signatureState = "尚未检查"
    @State private var needsMigration = false
    @State private var targetState = "未运行"
    @State private var connectionPackage: URL?
    @State private var connectionPackageWorkspace: URL?
    @State private var phoneCount = 0
    @State private var computerCount = 0
    @State private var runtimeMode = "等待本次启动回执"
    @State private var phoneRuntime = "本次未运行"
    @State private var computerRuntime = "本次未运行"

    var body: some View {
        Form {
            Section {
                LCAnalysisContext(title: model.displayName, detail: targetState)
                stateRow("本次运行", runtimeMode)
                stateRow("Gadget", gadgetLoad)
                stateRow("下次启动", installed ? (automatic ? "手机自动脚本" : "电脑连接") : "尚未启用")
            } footer: {
                Text("以本次运行回执为准。脚本已加载不代表 Hook 已命中。")
            }
            if installed {
                Picker("调试方式", selection: $scriptPage) {
                    Text("手机脚本").tag("phone")
                    Text("电脑连接").tag("computer")
                }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                if scriptPage == "phone" {
                Section {
                    stateRow("本次手机脚本", phoneRuntime)
                    NavigationLink { LCFridaStartupScriptsView(model: model) } label: {
                        LCToolRow(title: "配置手机自动脚本", subtitle: "已选择 \(phoneCount) 个 · 随目标启动加载", symbol: "iphone")
                    }
                } header: { Label("手机自动脚本", systemImage: "iphone") } footer: {
                    Text("在手机上执行，无需电脑；与电脑连接包的脚本选择相互独立。")
                }
                }
                if scriptPage == "computer" {
                Section {
                    stateRow("本次电脑脚本", computerRuntime)
                    NavigationLink { LCFridaStartupScriptsView(model: model, computer: true) } label: {
                        LCToolRow(title: "配置电脑连接脚本", subtitle: "连接包已选 \(computerCount) 个 · 由电脑加载", symbol: "desktopcomputer")
                    }
                } header: { Label("电脑连接脚本", systemImage: "desktopcomputer") } footer: {
                    Text(automatic ? "下次启动仍为手机模式。如需电脑连接，请进入配置页切换、保存并重启目标。" : "电脑连接后加载；配置连接包不表示电脑已连接。")
                }
                }
                Section {
                    NavigationLink { LCAppLogsView(model: model, initialSource: scriptPage == "phone" ? .phone : .computer) } label: {
                        LCToolRow(title: scriptPage == "phone" ? "查看手机脚本输出" : "查看电脑回传输出", subtitle: "按会话搜索、复制和导出日志", symbol: "text.alignleft")
                    }
                    NavigationLink { LCFridaVersionsView(model: model) } label: {
                        LCToolRow(title: "Gadget 版本", subtitle: "两种运行方式共用调试环境", symbol: "square.stack")
                    }
                } header: { Text("lc.tools.environmentAndLogs".loc) }
            }
            Section {
                HStack {
                    Text("Gadget").font(.headline)
                    Spacer()
                    LCStatusTag(text: installed ? "已准备" : "未启用", active: installed)
                }
                HStack {
                    Text("版本与架构").foregroundStyle(.secondary)
                    Spacer()
                    Text(gadgetVersion + " · arm64")
                }.font(.subheadline)
                if installed && !automatic && scriptPage == "computer" {
                    HStack {
                        Text("设备端口").foregroundStyle(.secondary)
                        Spacer()
                        Text(String(port)).monospacedDigit()
                    }.font(.subheadline)
                } else if !installed {
                    Button { Task { await prepare() } } label: {
                        Label("启用 Frida 调试", systemImage: "plus.circle")
                    }.disabled(busy || model.isAppRunning)
                }
                if installed && needsMigration {
                    Button("更新调试配置") { Task { await prepare() } }.disabled(busy || model.isAppRunning)
                }
                if busy { ProgressView("正在准备或签名…") }
            } header: { Text("调试环境") } footer: {
                if model.isAppRunning && !installed { Text("先关闭此 App 的测试窗口，再启用 Gadget。") }
            }
            Section {
                DisclosureGroup("签名与运行详情") {
                    stateRow("签名", signatureState)
                    stateRow("目标进程", targetState)
                    stateRow("Gadget 加载", gadgetLoad)
                }
            }
            if signingPending {
                Section {
                    Label(IOSVMDeviceSigning.configured ? "需要手机签名" : "等待配置手机签名证书", systemImage: "signature")
                    if let signingError { Text(signingError).font(.caption).foregroundStyle(.red) }
                    if IOSVMDeviceSigning.configured {
                        Button("在手机完成签名") { Task { await signOnDevice() } }.disabled(busy || model.isAppRunning)
                    } else {
                        Text("在 iAppVM 设置中导入与安装身份匹配的 .p12 证书，即可在手机签名。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        DisclosureGroup("电脑签名备用方式") {
                            Button("请求电脑签名") {
                                do {
                                    if let disk = NSDictionary(contentsOfFile: model.appInfo.bundlePath() + "/LCAppInfo.plist") as? [String: Any] {
                                        model.appInfo.info().setDictionary(disk)
                                    }
                                    try LCFridaSetup.requestSigning(model.appInfo)
                                    refresh()
                                } catch { message = error.localizedDescription }
                            }.disabled(busy)
                            Text("连接 USB，运行 python3 scripts/sync-device-guests.py --watch。")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                } header: { Text("签名") } footer: {
                    Text("签名成功后即可打开独立测试窗口。失败后可以在此重试。")
                }
            }
            if installed && !automatic && scriptPage == "computer" {
                Section {
                    Button { UIPasteboard.general.string = "iproxy -s 127.0.0.1 27043:\(port)"; message = "已复制。多台设备连接时需在 iproxy 命令中添加 -u 设备UDID。" } label: {
                        LCToolRow(title: "1. USB 端口转发", subtitle: "复制命令，在电脑终端运行", symbol: "cable.connector", accessory: "doc.on.doc")
                    }.buttonStyle(.plain)
                    Button { copyCommand() } label: {
                        LCToolRow(title: "2. 连接 Frida", subtitle: "启动目标 App 后，在另一终端执行", symbol: "terminal", accessory: "doc.on.doc")
                    }.buttonStyle(.plain)
                    Button {
                        do {
                            if let connectionPackageWorkspace { LCManagedDirectory.cleanup(connectionPackageWorkspace) }
                            let archive = try LCFridaConnectionPackage.create(app: model.appInfo)
                            connectionPackageWorkspace = archive.deletingLastPathComponent()
                            connectionPackage = archive
                        }
                        catch { message = error.localizedDescription }
                    } label: { Label("生成电脑连接包", systemImage: "shippingbox") }
                    if #available(iOS 16.0, *), let connectionPackage { ShareLink("分享连接包", item: connectionPackage) }
                } header: { Text("电脑连接") } footer: {
                    Text("连接命令中的 your-script.js 替换为自己的脚本路径。连接包包含匹配版本说明、所选脚本和可回传心跳/日志的客户端。包内含连接口令，请勿公开分享。标准 CLI 不自动回传心跳。")
                }
                Section {
                    Toggle("启动时等待 Frida", isOn: $wait)
                        .onChange(of: wait) { value in
                            do { try LCFridaSetup.setWait(value, app: model.appInfo) }
                            catch { message = error.localizedDescription }
                        }
                } header: { Text("启动模式") } footer: {
                    Text("默认正常打开 App 后再连接。启用等待适合观察启动阶段，App 会暂停到 Frida 连接并恢复执行。修改后重新启动生效。")
                }
                Section {
                    DisclosureGroup("Hook 支持范围") {
                        Text("当前环境中，Interceptor Hook 的目标需要预插桩。Gadget 可自动准备；具体函数的偏移与脚本需要按 App 适配。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.font(.subheadline)
                }
            }
        }
        .navigationTitle("Hook 调试")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refresh()
            if !choseInitialPage { scriptPage = automatic ? "phone" : "computer"; choseInitialPage = true }
        }
        .task {
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
        .onDisappear {
            if let connectionPackageWorkspace { LCManagedDirectory.cleanup(connectionPackageWorkspace) }
            connectionPackageWorkspace = nil
            connectionPackage = nil
        }
        .refreshable { refresh() }
        .alert("Frida 调试", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func refresh() {
        installed = LCFridaSetup.enabled(model.appInfo)
        signingError = nil; automatic = false; phoneCount = 0; computerCount = 0
        if let folder = LCFridaSetup.folder(for: model.appInfo) {
            needsMigration = !FileManager.default.fileExists(atPath: folder.appendingPathComponent(LCFridaScriptStore.manifestName).path)
            if let selection = try? LCFridaScriptStore.selection(folder: folder) {
                gadgetVersion = selection.gadgetVersion ?? "旧配置，版本未记录"
                phoneCount = selection.scripts.count; computerCount = selection.computerScripts?.count ?? 0
                needsMigration = needsMigration || selection.owner != model.appInfo.relativeBundlePath
            }
        }
        if let config = try? LCFridaSetup.config(model.appInfo), let interaction = config["interaction"] as? [String: Any] {
            automatic = interaction["type"] as? String == "script-directory"
            wait = interaction["on_load"] as? String == "wait"
            port = interaction["port"] as? Int ?? 27042
        }
        let disk = NSDictionary(contentsOfFile: model.appInfo.bundlePath() + "/LCAppInfo.plist")
        signingPending = disk?["IOSVMNeedsExternalSigning"] as? Bool ?? false
        let requestURL = LCPath.docPath.appendingPathComponent("iOSVM/SigningRequests/" + model.appInfo.relativeBundlePath + ".json")
        if let data = try? LCFridaLogBoundary.readData(requestURL, inside: LCPath.docPath, maximumBytes: 262144),
           let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            signingPending = signingPending || request["state"] as? String != "ready"
            signingError = request["error"] as? String
        }
        signatureState = signingPending ? "待签名或签名失败" : ((disk?["IOSVMDeviceSigned"] as? Bool == true || disk?["IOSVMExternallySigned"] as? Bool == true) ? "已有签名记录" : "尚无手机签名记录")
        refreshRuntime()
    }

    private func stateRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            Text(value).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 3)
    }
    private func refreshRuntime() {
        gadgetLoad = "尚无本次启动回执"
        runtimeMode = "目标未运行"; phoneRuntime = "本次未运行"; computerRuntime = "本次未运行"; targetState = "未运行"
        guard let root = (model.uiSelectedContainer ?? model.uiContainers.first)?.containerURL else { return }
        let records = IOSVMProcessRegistry.shared.records(forBundle: model.appInfo.relativeBundlePath).compactMap { $0 as? [String: Any] }.filter { $0["container"] as? String == root.lastPathComponent }
        let current = records.max { ($0["startedAt"] as? Double ?? 0) < ($1["startedAt"] as? Double ?? 0) }
        let pid = current?["pid"] as? Int ?? 0
        let startedAt = current?["startedAt"] as? Double ?? 0
        let state = current?["state"] as? String ?? ""
        targetState = model.isOperationBusy ? "准备或签名中" : (["preparing":"准备启动", "spawned":"进程已创建", "running":"运行中 · PID " + String(pid), "stopping":"正在关闭", "failed":"启动失败", "exited":"已退出", "orphaned":"旧进程仍占用", "unconfirmed":"旧状态未确认"][state] ?? "未运行")
        let matchingSession = LCDebugSession.list(root: root).first(where: { $0.pid == pid && ($0.value["startedAt"] as? Double ?? 0) >= startedAt - 1 })
        if let session = matchingSession {
            let plugins = session.value["plugins"] as? [[String: Any]] ?? []
            if let gadget = plugins.first(where: { $0["file"] as? String == LCFridaSetup.library }) {
                gadgetLoad = gadget["status"] as? String == "loaded" ? (state == "running" ? "本次进程已加载" : "上次进程已加载") : (gadget["error"] as? String ?? "加载失败")
            } else { gadgetLoad = "已收到启动回执，等待加载结果" }
        }
        let clientURL = root.appendingPathComponent("Library/iOSVM/Debug/client.json")
        let client = (try? Data(contentsOf: clientURL)).flatMap { data -> [String:Any]? in
            guard data.count <= 32768 else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String:Any]
        }
        let status = LCFridaExecutionStatus.evaluate(record:current, session:matchingSession?.value, client:client, now:Date().timeIntervalSince1970, phoneStates:matchingSession.map { LCPhoneScriptLog.states(folder:$0.folder,session:$0.value) })
        runtimeMode = status.mode; phoneRuntime = status.phone; computerRuntime = status.computer

    }

    @MainActor private func prepare() async {
        busy = true
        defer { busy = false; refresh() }
        do {
            try await LCFridaSetup.prepare(model.appInfo)
            model.uiTweakFolder = model.appInfo.tweakFolder
            let name = model.appInfo.tweakFolder!
            let shared = DataManager.shared.model
            if !shared.tweakFolderNames.contains(name) { shared.tweakFolderNames.append(name) }
            if IOSVMDeviceSigning.configured { try await IOSVMDeviceSigning.sign(model.appInfo) }
            else { try LCFridaSetup.requestSigning(model.appInfo) }
            message = "Frida 已启用。选择手机自动脚本或电脑连接脚本，保存运行方式后重新启动目标。"
        } catch { message = error.localizedDescription }
    }

    @MainActor private func signOnDevice() async {
        busy = true
        defer { busy = false; refresh() }
        do {
            try await IOSVMDeviceSigning.sign(model.appInfo)
            message = "手机签名完成，可以启动 App。"
        } catch { message = error.localizedDescription }
    }

    private func copyCommand() {
        do {
            let config = try LCFridaSetup.config(model.appInfo)
            guard let interaction = config["interaction"] as? [String: Any], let token = interaction["token"] as? String,
                  token.range(of: "^[a-f0-9]+$", options: .regularExpression) != nil else { throw "Gadget 口令格式不正确。" }
            UIPasteboard.general.string = "frida -H 127.0.0.1:27043 --token '" + token + "' -n Gadget -l your-script.js"
            message = "已复制连接命令。将 your-script.js 替换为你的脚本路径。"
        } catch { message = error.localizedDescription }
    }
}
