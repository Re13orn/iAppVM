import SwiftUI
import UIKit

/// Task-oriented home for one imported app.
///
/// The existing `LCAppSettingsView` remains the complete configuration surface.
/// This screen keeps the common jailbreak-style testing workflows in one place.
struct LCAppWorkbenchView: View {
    @ObservedObject var model: LCAppModel
    @EnvironmentObject private var sharedModel: SharedModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    @State private var runtime = Runtime()
    @State private var health: [HealthItem] = HealthItem.placeholders
    @State private var preflightBlockingCount = 0
    @State private var toolState = ToolState()
    @State private var busyAction = false
    @State private var alertMessage: String?
    @State private var showPreflight = false

    private let processChanges = NotificationCenter.default.publisher(for: Notification.Name("IOSVMProcessesDidChange"))
    private var usesExpandedLayout: Bool {
        switch dynamicTypeSize {
        case .xxLarge, .xxxLarge, .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
            return true
        default:
            return false
        }
    }

    private var healthColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: usesExpandedLayout ? 2 : 4)
    }

    private var capabilityColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: usesExpandedLayout ? 1 : 2)
    }

    private var appIcon: UIImage {
        model.appInfo.iconIsDarkIcon(darkModeIcon)
            ?? UIImage(systemName: "app.dashed")
            ?? UIImage()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                runtimeCard

                LazyVGrid(columns: healthColumns, spacing: 8) {
                    ForEach(health) { item in
                        HealthTile(item: item)
                    }
                }
                .accessibilityElement(children: .contain)

                sectionHeader("测试能力", detail: "按任务进入")

                LazyVGrid(columns: capabilityColumns, spacing: 12) {
                    NavigationLink {
                        LCNetworkView(model: model)
                    } label: {
                        CapabilityCard(
                            title: "网络分析",
                            subtitle: "捕获请求并配置 HTTP / SOCKS5 代理",
                            status: toolState.network,
                            symbol: "network",
                            badge: toolState.captureBadge
                        )
                    }

                    NavigationLink {
                        LCFridaView(model: model)
                    } label: {
                        CapabilityCard(
                            title: "Hook 调试",
                            subtitle: "Gadget、启动脚本、电脑连接与日志",
                            status: toolState.hook,
                            symbol: "terminal",
                            badge: nil
                        )
                    }

                    NavigationLink {
                        LCAppDataToolsView(model: model)
                    } label: {
                        CapabilityCard(
                            title: "文件与 Keychain",
                            subtitle: "浏览沙盒、文件变化与当前 Guest 的 Keychain",
                            status: toolState.sandbox,
                            symbol: "externaldrive",
                            badge: nil
                        )
                    }

                    NavigationLink {
                        LCAppLogsView(model: model)
                    } label: {
                        CapabilityCard(
                            title: "lc.tools.logs".loc,
                            subtitle: "lc.tools.logsDescription".loc,
                            status: "lc.tools.logsSources".loc,
                            symbol: "text.alignleft",
                            badge: nil
                        )
                    }
                }
                .buttonStyle(.plain)

                sectionHeader("检查与设置", detail: nil)

                VStack(spacing: 0) {
                    NavigationLink {
                        LCCompatibilityDiagnosticsView(model: model)
                    } label: {
                        WorkbenchRow(
                            title: "lc.tools.launchDiagnostics".loc,
                            subtitle: preflightBlockingCount == 0 ? "查看启动、首屏、插件与网络阶段" : "\(preflightBlockingCount) 个启动阻断项",
                            symbol: "waveform.path.ecg",
                            status: preflightBlockingCount == 0 ? "阶段" : "需处理",
                            emphasized: preflightBlockingCount > 0
                        )
                    }

                    Divider().padding(.leading, 55)

                    NavigationLink {
                        LCGuestSessionView(model: model)
                    } label: {
                        WorkbenchRow(
                            title: "运行记录与授权",
                            subtitle: runtime.hasRecord ? runtime.detail : "查看进程、启动记录与文件权限",
                            symbol: "list.bullet.rectangle",
                            status: nil,
                            emphasized: false
                        )
                    }

                    Divider().padding(.leading, 55)

                    NavigationLink {
                        LCAppSettingsView(model: model)
                    } label: {
                        WorkbenchRow(
                            title: "兼容性与高级设置",
                            subtitle: "容器、运行模式、兼容性与高级选项",
                            symbol: "gearshape",
                            status: nil,
                            emphasized: false
                        )
                    }
                }
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(model.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    LCAppSettingsView(model: model)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("兼容性与高级设置")
            }
        }
        .background(
            NavigationLink(isActive: $showPreflight) {
                LCLaunchPreflightView(model: model)
            } label: {
                EmptyView()
            }
            .hidden()
        )
        .alert("App 工作台", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("确定") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .onAppear(perform: refresh)
        .onReceive(processChanges) { _ in refresh() }
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 13) {
                IconImageView(icon: appIcon)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text("\(model.version) · \(model.bundleIdentifier)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                RuntimeBadge(text: runtime.badgeText, active: runtime.isActive)
            }

            Divider().opacity(0.7)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("独立测试窗口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(runtime.detail)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if runtime.isActive {
                    Button {
                        stopTarget()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .foregroundStyle(.red)
                    .disabled(busyAction || runtime.state == "stopping")

                    Button {
                        Task { await restartTarget() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 20, height: 20)
                    }
                    .accessibilityLabel("重新启动")
                    .disabled(busyAction || runtime.state == "stopping")
                } else {
                    Button {
                        Task { await launchTarget() }
                    } label: {
                        if busyAction || model.isLaunchPreparationBusy {
                            Label("正在启动", systemImage: "hourglass")
                        } else {
                            Label("启动", systemImage: "play.fill")
                        }
                    }
                    .disabled(busyAction || model.isLaunchPreparationBusy)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if let container = runtime.container, !container.isEmpty {
                Label(containerDisplayName(container), systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.08),
                            Color.clear,
                            Color(uiColor: .secondarySystemGroupedBackground).opacity(0.01)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.13), lineWidth: 0.75)
                }
        }
    }

    private func sectionHeader(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    @MainActor
    private func refresh() {
        let records = IOSVMProcessRegistry.shared.records(forBundle: model.appInfo.relativeBundlePath)
            .compactMap { $0 as? [String: Any] }
        let activeStates = Set(["preparing", "spawned", "running", "stopping"])
        let active = records.filter { activeStates.contains($0["state"] as? String ?? "") }
            .max { ($0["startedAt"] as? Double ?? 0) < ($1["startedAt"] as? Double ?? 0) }
        let latest = active ?? records.max { ($0["startedAt"] as? Double ?? 0) < ($1["startedAt"] as? Double ?? 0) }

        runtime = Runtime(
            state: latest?["state"] as? String ?? "idle",
            pid: latest?["pid"] as? Int,
            container: latest?["container"] as? String,
            hasRecord: latest != nil,
            active: active != nil
        )

        let issues = LCLaunchPreflight.check(model, multitask: true)
        preflightBlockingCount = issues.filter(\.blocking).count

        let signingNeedsAttention = issues.contains { ["signing", "sign-request"].contains($0.id) }
        let signing: HealthItem
        if model.appInfo.isShared || model.appInfo.is32bit {
            signing = HealthItem(title: "签名", value: "不适用", symbol: "seal", tone: .inactive)
        } else if signingNeedsAttention {
            signing = HealthItem(
                title: "签名",
                value: IOSVMDeviceSigning.configured ? "需重签" : "未配置",
                symbol: "exclamationmark.shield",
                tone: .warning
            )
        } else {
            signing = HealthItem(title: "签名", value: "就绪", symbol: "checkmark.seal", tone: .ready)
        }

        let fridaFolder = LCFridaSetup.folder(for: model.appInfo)
        let selection = fridaFolder.flatMap { try? LCFridaScriptStore.selection(folder: $0) }
        let gadgetEnabled = LCFridaSetup.enabled(model.appInfo)
        let gadget = HealthItem(
            title: "Gadget",
            value: gadgetEnabled ? (selection?.gadgetVersion ?? LCFridaVersions.builtin.version) : "未启用",
            symbol: "point.3.connected.trianglepath.dotted",
            tone: gadgetEnabled ? .ready : .inactive
        )
        let scriptValue: String
        if gadgetEnabled {
            if selection?.automatic == true {
                scriptValue = "\(selection?.scripts.count ?? 0) 个"
            } else if selection != nil {
                scriptValue = "监听"
            } else {
                scriptValue = "待配置"
            }
        } else {
            scriptValue = "未配置"
        }
        let scripts = HealthItem(
            title: "脚本",
            value: scriptValue,
            symbol: "chevron.left.forwardslash.chevron.right",
            tone: gadgetEnabled ? .ready : .inactive
        )

        let network = try? LCTestPresetManager.network(model)
        let proxyValue: String
        let proxyTone: HealthTone
        if let network {
            if network.proxyType == "off" {
                proxyValue = network.capture ? "仅捕获" : "关闭"
                proxyTone = network.capture ? .ready : .inactive
            } else {
                proxyValue = network.proxyType.uppercased()
                proxyTone = .ready
            }
        } else {
            proxyValue = "配置异常"
            proxyTone = .warning
        }
        let proxy = HealthItem(title: "代理", value: proxyValue, symbol: "network", tone: proxyTone)
        health = [signing, gadget, scripts, proxy]

        let networkBadge: String?
        if let network, network.proxyType != "off" {
            networkBadge = network.proxyType.uppercased()
        } else if network?.capture == true {
            networkBadge = "捕获"
        } else {
            networkBadge = nil
        }
        let networkStatus: String
        if let network {
            if network.proxyType == "off" {
                networkStatus = network.capture ? "仅捕获" : "尚未启用"
            } else {
                networkStatus = network.proxyType.uppercased() + (network.capture ? " · 捕获" : " · 未捕获")
            }
        } else {
            networkStatus = "配置异常"
        }
        toolState = ToolState(
            network: networkStatus,
            captureBadge: networkBadge,
            hook: gadgetEnabled ? "Gadget \(selection?.gadgetVersion ?? LCFridaVersions.builtin.version)" : "Gadget 未启用",
            sandbox: "\(model.uiContainers.count) 个数据容器"
        )
    }

    private func containerDisplayName(_ folderName: String) -> String {
        guard let index = model.uiContainers.firstIndex(where: { $0.folderName == folderName }) else {
            return "沙盒"
        }
        let container = model.uiContainers[index]
        return container.name == container.folderName ? "沙盒 \(index + 1)" : container.name
    }

    @MainActor
    private func launchTarget() async {
        guard !busyAction else { return }
        busyAction = true
        defer { busyAction = false }
        do {
            if model.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked,
               try await LCUtils.authenticateUser() == false {
                return
            }
            try await model.runApp(multitask: true)
            refresh()
        } catch is LCLaunchPreflight.Failure {
            showPreflight = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    @MainActor
    private func restartTarget() async {
        guard !busyAction else { return }
        busyAction = true
        stopTarget()

        var remaining = 0
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            remaining = activeRecordCount()
            if remaining == 0 { break }
        }
        guard remaining == 0 else {
            busyAction = false
            alertMessage = "目标窗口仍在关闭。请稍后再试。"
            return
        }
        do {
            try await model.runApp(multitask: true)
            refresh()
        } catch is LCLaunchPreflight.Failure {
            showPreflight = true
        } catch {
            alertMessage = error.localizedDescription
        }
        busyAction = false
    }

    @MainActor
    private func stopTarget() {
        let records = IOSVMProcessRegistry.shared.records(forBundle: model.appInfo.relativeBundlePath)
            .compactMap { $0 as? [String: Any] }
        let active = records.filter {
            ["preparing", "spawned", "running", "stopping"].contains($0["state"] as? String ?? "")
        }
        for record in active {
            guard let id = record["id"] as? String else { continue }
            NotificationCenter.default.post(
                name: Notification.Name("IOSVMStopGuest"),
                object: nil,
                userInfo: ["id": id]
            )
        }
        refresh()
    }

    @MainActor
    private func activeRecordCount() -> Int {
        IOSVMProcessRegistry.shared.records(forBundle: model.appInfo.relativeBundlePath)
            .compactMap { $0 as? [String: Any] }
            .filter { ["preparing", "spawned", "running", "stopping"].contains($0["state"] as? String ?? "") }
            .count
    }
}

private struct Runtime {
    var state = "idle"
    var pid: Int?
    var container: String?
    var hasRecord = false
    var active = false

    var isActive: Bool {
        active || ["preparing", "spawned", "running", "stopping"].contains(state)
    }

    var badgeText: String {
        switch state {
        case "preparing": return "准备中"
        case "spawned": return "正在打开"
        case "running": return active ? "运行中" : "已结束"
        case "stopping": return "正在关闭"
        case "orphaned": return "旧进程占用"
        case "failed": return "启动失败"
        default: return "未运行"
        }
    }

    var detail: String {
        if isActive, let pid, pid > 0 { return "PID \(pid) · 独立窗口" }
        switch state {
        case "failed": return "上次启动失败"
        case "orphaned": return "旧进程仍占用容器"
        default: return hasRecord ? "最近一次进程已结束" : "尚未启动"
        }
    }
}

private struct RuntimeBadge: View {
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(active ? Color.green : Color.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            (active ? Color.green : Color.secondary).opacity(0.1),
            in: Capsule()
        )
        .fixedSize()
    }
}

private enum HealthTone {
    case ready
    case inactive
    case warning

    var color: Color {
        switch self {
        case .ready: return .accentColor
        case .inactive: return .secondary
        case .warning: return .orange
        }
    }
}

private struct HealthItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let symbol: String
    let tone: HealthTone

    static let placeholders = [
        HealthItem(title: "签名", value: "检查中", symbol: "signature", tone: .inactive),
        HealthItem(title: "Gadget", value: "检查中", symbol: "point.3.connected.trianglepath.dotted", tone: .inactive),
        HealthItem(title: "脚本", value: "检查中", symbol: "chevron.left.forwardslash.chevron.right", tone: .inactive),
        HealthItem(title: "代理", value: "检查中", symbol: "network", tone: .inactive)
    ]
}

private struct HealthTile: View {
    let item: HealthItem

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: item.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.tone.color)
                .frame(height: 18)
                .accessibilityHidden(true)
            Text(item.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.28), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title)，\(item.value)")
    }
}

private struct CapabilityCard: View {
    let title: String
    let subtitle: String
    let status: String
    let symbol: String
    let badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)

                Spacer(minLength: 4)

                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.08), in: Capsule())
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            Text(title)
                .font(.headline)
                .padding(.top, 13)
                .lineLimit(1)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)

            Spacer(minLength: 12)

            Text(status)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 19, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开\(title)")
    }
}

private struct WorkbenchRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let status: String?
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(emphasized ? Color.orange : Color.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    (emphasized ? Color.orange : Color.accentColor).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(emphasized ? Color.orange : Color.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct ToolState {
    var network = "检查中"
    var captureBadge: String?
    var hook = "检查中"
    var sandbox = "检查中"
}
