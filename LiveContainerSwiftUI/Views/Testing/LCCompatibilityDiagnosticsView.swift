import SwiftUI

struct LCCompatibilityDiagnosticsView: View {
    @ObservedObject var model: LCAppModel
    @State private var preflightIssues: [LCLaunchPreflight.Issue] = []
    @State private var report: LCCompatibilityDiagnosticReport?
    @State private var safeModeActive = false
    @State private var safeModeBusy = false
    @State private var message: String?
    private let changes = NotificationCenter.default.publisher(
        for: Notification.Name("IOSVMProcessesDidChange")
    )

    var body: some View {
        List {
            Section {
                LCToolContext(
                    model: model,
                    title: "lc.tools.launchDiagnostics".loc,
                    subtitle: "按 IPA、签名、启动、首屏、插件和网络阶段定位问题。",
                    symbol: "waveform.path.ecg"
                )
                if let report {
                    Label(
                        report.recommendation,
                        systemImage: report.blockingCount == 0 ? "lightbulb" : "exclamationmark.octagon"
                    )
                    .font(.subheadline)
                    .foregroundStyle(report.blockingCount == 0 ? Color.primary : Color.orange)
                    Text("更新于 " + report.generatedAt.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("正在检查…")
                }
            }

            LCLaunchPreflightChecks(model: model, issues: $preflightIssues, busy: $safeModeBusy, didRefresh: reload)

            Section {
                if safeModeActive {
                    Label("安全模式已启用", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("当前配置跳过 TweakLoader、测试插件、JIT 和网络代理，仅用于判断是否是配置或插件导致启动失败。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        restoreSafeMode()
                    } label: {
                        Label("退出安全模式并恢复原配置", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.isAppRunning || safeModeBusy)
                } else {
                    Button {
                        Task { await launchSafeMode() }
                    } label: {
                        Label("以安全模式启动", systemImage: "shield.lefthalf.filled")
                    }
                    .disabled(model.isAppRunning || safeModeBusy)
                }
            } header: {
                Text("故障恢复").textCase(nil)
            } footer: {
                Text("安全模式会先保存原配置，保留 App 程序和数据容器；启动后可重新诊断，再恢复完整测试环境。")
            }

            if let report {
                ForEach(report.stages.filter { !["signing", "preflight"].contains($0.id) }) { stage in
                    Section {
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: symbol(stage.status))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(color(stage.status))
                                .frame(width: 28, height: 28)
                                .background(color(stage.status).opacity(0.1), in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(stage.title).font(.headline)
                                    Spacer(minLength: 8)
                                    Text(stage.status.title)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(color(stage.status))
                                }
                                Text(stage.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 3)
                        if let detail = stage.detail {
                            DisclosureGroup("技术详情") {
                                Text(detail)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.subheadline)
                        }
                        if let action = stage.action {
                            navigation(for: action)
                        }
                    }
                }
            }
        }
        .navigationTitle("lc.tools.launchDiagnostics".loc)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onReceive(changes) { _ in reload() }
        .refreshable { reload() }
        .alert("lc.tools.launchDiagnostics".loc, isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("确定") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private func navigation(for action: LCCompatibilityStage.Action) -> some View {
        switch action {
        case .preflight, .signing:
            EmptyView() // Repair controls are already shown above the runtime stages.
        case .frida:
            NavigationLink("打开 Frida 调试") { LCFridaView(model: model) }
        case .network:
            NavigationLink("检查网络配置") { LCNetworkView(model: model) }
        case .sandbox:
            NavigationLink("检查应用文件") { LCAppSandboxView(model: model) }
        case .process:
            NavigationLink("查看运行记录") { LCGuestSessionView(model: model) }
        case .logs:
            NavigationLink("查看进程日志") { LCAppLogsView(model: model, initialSource: .process) }
        case .settings:
            NavigationLink("打开兼容性与高级设置") { LCAppSettingsView(model: model) }
        }
    }

    private func reload() {
        preflightIssues = LCLaunchPreflight.check(model)
        report = LCCompatibilityDiagnostics.evaluate(model)
        safeModeActive = LCAppSafeMode.isActive(model)
    }

    @MainActor
    private func launchSafeMode() async {
        safeModeBusy = true
        defer { safeModeBusy = false }
        do {
            try LCAppSafeMode.activate(model)
            reload()
            try await model.runApp(multitask: true)
            reload()
        } catch is LCLaunchPreflight.Failure {
            reload()
            message = "安全模式已保存，但启动检查仍未通过。请先处理诊断中的阻断项。"
        } catch {
            reload()
            message = error.localizedDescription
        }
    }

    private func restoreSafeMode() {
        safeModeBusy = true
        defer { safeModeBusy = false }
        do {
            try LCAppSafeMode.restore(model)
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func symbol(_ status: LCCompatibilityStageStatus) -> String {
        switch status {
        case .passed: return "checkmark"
        case .warning: return "exclamationmark"
        case .blocked: return "xmark"
        case .pending: return "clock"
        case .unavailable: return "minus"
        }
    }

    private func color(_ status: LCCompatibilityStageStatus) -> Color {
        switch status {
        case .passed: return .green
        case .warning: return .orange
        case .blocked: return .red
        case .pending: return .accentColor
        case .unavailable: return .secondary
        }
    }
}
