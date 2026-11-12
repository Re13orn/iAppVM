import Foundation

enum LCCompatibilityStageStatus {
    case passed
    case warning
    case blocked
    case pending
    case unavailable

    var title: String {
        switch self {
        case .passed: return "通过"
        case .warning: return "需注意"
        case .blocked: return "未通过"
        case .pending: return "等待验证"
        case .unavailable: return "不可用"
        }
    }
}

struct LCCompatibilityStage: Identifiable {
    enum Action {
        case preflight
        case signing
        case frida
        case network
        case sandbox
        case process
        case logs
        case settings
    }

    let id: String
    let title: String
    let status: LCCompatibilityStageStatus
    let summary: String
    let detail: String?
    let action: Action?
}

struct LCCompatibilityDiagnosticReport {
    let generatedAt: Date
    let stages: [LCCompatibilityStage]
    let recommendation: String

    var blockingCount: Int {
        stages.filter { $0.status == .blocked }.count
    }
}

enum LCCompatibilityDiagnostics {
    @MainActor
    static func evaluate(_ model: LCAppModel) -> LCCompatibilityDiagnosticReport {
        let issues = LCLaunchPreflight.check(model)
        let records = IOSVMProcessRegistry.shared.records(forBundle: model.appInfo.relativeBundlePath)
            .compactMap { $0 as? [String: Any] }
        let current = records.max { ($0["startedAt"] as? Double ?? 0) < ($1["startedAt"] as? Double ?? 0) }
        let pid = current?["pid"] as? Int ?? 0
        let startedAt = current?["startedAt"] as? Double ?? 0
        let container = model.uiSelectedContainer ?? model.uiContainers.first
        let session = container.flatMap { selected in
            LCDebugSession.list(root: selected.containerURL).first {
                $0.pid == pid && ($0.value["startedAt"] as? Double ?? 0) >= startedAt - 1
            }
        }
        let stageHistory = session?.value["stages"] as? [[String: Any]] ?? []
        let stageIDs = Set(stageHistory.compactMap { $0["stage"] as? String })

        var stages: [LCCompatibilityStage] = []
        let infoPath = model.appInfo.bundlePath() + "/Info.plist"
        let executable = model.appInfo.bundlePath() + "/" +
            ((NSDictionary(contentsOfFile: infoPath)?["CFBundleExecutable"] as? String) ?? "")
        var encrypted = false
        var architecture = "未知"
        if FileManager.default.fileExists(atPath: executable) {
            var cputype: cpu_type_t = 0
            let parseError = LCParseMachO(executable, true) { _, header, _, _ in
                guard let header else { return }
                encrypted = encrypted || LCIsMachOEncrypted(header)
                cputype = header.pointee.cputype
            }
            if parseError == nil {
                architecture = cputype == CPU_TYPE_ARM64 ? "arm64" : "非 arm64"
            }
        }
        let bundleStatus: LCCompatibilityStageStatus
        let bundleSummary: String
        if !FileManager.default.fileExists(atPath: infoPath) || !FileManager.default.fileExists(atPath: executable) {
            bundleStatus = .blocked
            bundleSummary = "应用包或主程序缺失"
        } else if encrypted {
            bundleStatus = .blocked
            bundleSummary = "主程序仍为加密 IPA，请使用已解密版本"
        } else if architecture != "arm64" {
            bundleStatus = .warning
            bundleSummary = "检测到 \(architecture) 主程序"
        } else {
            bundleStatus = .passed
            bundleSummary = "应用包完整，arm64，未检测到 cryptid"
        }
        stages.append(.init(
            id: "package",
            title: "IPA 与主程序",
            status: bundleStatus,
            summary: bundleSummary,
            detail: executable,
            action: bundleStatus == .passed ? nil : .sandbox
        ))

        let signingIssues = issues.filter {
            ["signing", "sign-request", "sign-key", "host-expired"].contains($0.id)
        }
        let signingBlocked = signingIssues.contains(where: \.blocking)
        stages.append(.init(
            id: "signing",
            title: "签名与描述文件",
            status: signingBlocked ? .blocked : (signingIssues.isEmpty ? .passed : .warning),
            summary: signingBlocked ? signingIssues.first!.title : (signingIssues.isEmpty ? "未发现已知签名阻断" : signingIssues.first!.title),
            detail: signingIssues.map { $0.title + "：" + $0.detail }.joined(separator: "\n").nilIfEmpty,
            action: signingIssues.isEmpty ? nil : .signing
        ))

        let blocking = issues.filter(\.blocking)
        stages.append(.init(
            id: "preflight",
            title: "启动前配置",
            status: blocking.isEmpty ? (issues.isEmpty ? .passed : .warning) : .blocked,
            summary: blocking.isEmpty ? (issues.isEmpty ? "未发现已知阻断项" : "\(issues.count) 个提示") : "\(blocking.count) 个阻断项",
            detail: issues.map { $0.title + "：" + $0.detail }.joined(separator: "\n").nilIfEmpty,
            action: blocking.isEmpty ? nil : .preflight
        ))

        let state = current?["state"] as? String ?? ""
        let processStatus: LCCompatibilityStageStatus
        let processSummary: String
        switch state {
        case "running":
            processStatus = .passed
            processSummary = "测试进程运行中 · PID \(pid)"
        case "preparing", "spawned":
            processStatus = .pending
            processSummary = "进程正在准备"
        case "failed", "interrupted":
            processStatus = .blocked
            processSummary = (current?["reason"] as? String) ?? "上次启动失败"
        case "stopping":
            processStatus = .pending
            processSummary = "进程正在关闭"
        case "exited":
            processStatus = .warning
            processSummary = "进程已结束，无法确认页面是否曾可用"
        case "orphaned", "unconfirmed":
            processStatus = .warning
            processSummary = (current?["reason"] as? String) ?? "运行状态未确认"
        default:
            processStatus = .pending
            processSummary = "尚未启动测试进程"
        }
        stages.append(.init(
            id: "process",
            title: "进程创建",
            status: processStatus,
            summary: processSummary,
            detail: current.map { value in
                "PID \(value["pid"] as? Int ?? 0) · \(value["container"] as? String ?? "未记录容器")"
            },
            action: processStatus == .blocked ? .process : nil
        ))

        let mainEntered = stageIDs.contains("mainEntered")
        let firstAppearance = stageIDs.contains("firstUIAppearanceObserved")
        let runtimeStatus: LCCompatibilityStageStatus
        let runtimeSummary: String
        if let last = stageHistory.last?["stage"] as? String {
            if firstAppearance {
                runtimeStatus = .passed
                runtimeSummary = "首屏控制器已出现"
            } else if mainEntered {
                runtimeStatus = state == "running" ? .warning : .pending
                runtimeSummary = "已进入 main，但尚未观察到首屏控制器"
            } else {
                runtimeStatus = .pending
                runtimeSummary = "当前阶段：\(stageLabel(last))"
            }
        } else {
            runtimeStatus = .pending
            runtimeSummary = "尚无本次运行阶段记录"
        }
        stages.append(.init(
            id: "runtime",
            title: "运行与首屏",
            status: runtimeStatus,
            summary: runtimeSummary,
            detail: stageHistory.suffix(12).compactMap { event in
                guard let name = event["stage"] as? String else { return nil }
                return stageLabel(name)
            }.joined(separator: " → ").nilIfEmpty,
            action: runtimeStatus == .warning || runtimeStatus == .blocked ? .logs : nil
        ))

        let plugins = session?.value["plugins"] as? [[String: Any]] ?? []
        let fridaEnabled = LCFridaSetup.enabled(model.appInfo)
        let failedPlugins = plugins.filter { $0["status"] as? String != "loaded" }
        stages.append(.init(
            id: "plugins",
            title: "插件与注入",
            status: !fridaEnabled ? .unavailable : (plugins.isEmpty ? .pending : (failedPlugins.isEmpty ? .passed : .warning)),
            summary: !fridaEnabled ? "未启用 Frida Gadget" : (plugins.isEmpty ? "尚无本次插件加载回执" : "\(plugins.count - failedPlugins.count)/\(plugins.count) 个已加载"),
            detail: plugins.map {
                ($0["file"] as? String ?? "未知插件") + "：" + ($0["status"] as? String ?? "未确认")
            }.joined(separator: "\n").nilIfEmpty,
            action: fridaEnabled ? .frida : nil
        ))

        let network = try? LCTestPresetManager.network(model)
        let receipt = networkReceipt(model)
        let networkConfigured = network.map { $0.capture || $0.proxyType != "off" } ?? false
        let receiptLoaded = receipt?["configurationLoaded"] as? Bool == true
        stages.append(.init(
            id: "network",
            title: "网络配置",
            status: !networkConfigured ? .unavailable : (receiptLoaded ? .passed : .warning),
            summary: !networkConfigured ? "未启用捕获或代理" : (receiptLoaded ? "目标已报告配置加载" : "已保存配置，尚无本次加载回执"),
            detail: network.map {
                $0.proxyType == "off"
                    ? ($0.capture ? "仅流量捕获" : "关闭")
                    : "\($0.proxyType.uppercased()) · \($0.host):\($0.port)"
            },
            action: networkConfigured ? .network : nil
        ))

        stages.append(.init(
            id: "business",
            title: "业务页面可用",
            status: .pending,
            summary: firstAppearance ? "首屏已出现；业务功能仍需人工验证" : "无法自动判断白屏或业务功能",
            detail: "iAppVM 只能确认进程和 UI 外观阶段，不能替用户判断登录、钱包、交易或网络业务是否真正可用。",
            action: nil
        ))

        let recommendation: String
        if let firstBlocked = stages.first(where: { $0.status == .blocked }) {
            recommendation = "先处理“\(firstBlocked.title)”：\(firstBlocked.summary)"
        } else if runtimeStatus == .warning && mainEntered {
            recommendation = "进程已进入 main 但首屏未确认。建议关闭最近启用的插件，使用安全模式重试并查看进程控制台。"
        } else if processStatus == .pending {
            recommendation = "配置已准备，启动 App 后回到这里查看进程、插件、首屏和网络阶段。"
        } else {
            recommendation = "已知自动检查通过。仍需人工确认业务页面和关键功能。"
        }
        return LCCompatibilityDiagnosticReport(generatedAt: Date(), stages: stages, recommendation: recommendation)
    }

    private static func networkReceipt(_ model: LCAppModel) -> [String: Any]? {
        guard let container = model.uiSelectedContainer ?? model.uiContainers.first else { return nil }
        let file = container.containerURL.appendingPathComponent("Library/iOSVM/Network/status.json")
        guard let data = try? LCFridaLogBoundary.readData(file, inside: container.containerURL, maximumBytes: 65536) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func stageLabel(_ value: String) -> String {
        [
            "validating": "验证启动配置",
            "phoneScriptCaptureReady": "脚本通道就绪",
            "environmentReady": "运行环境就绪",
            "debugCompatibility": "兼容处理完成",
            "loadingExecutable": "加载主程序",
            "mainEntered": "进入 main",
            "pluginsLoaded": "插件加载完成",
            "windowVisible": "窗口显示",
            "firstUIAppearanceObserved": "首屏控制器出现",
            "launchFailed": "启动失败"
        ][value] ?? value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
