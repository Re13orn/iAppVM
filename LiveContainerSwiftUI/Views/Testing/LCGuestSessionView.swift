import SwiftUI

private struct LCGuestSession: Identifiable {
    let value: [String: Any]
    var id: String { value["id"] as? String ?? "" }
    var state: String { value["state"] as? String ?? "" }
    var active: Bool { ["preparing", "spawned", "running", "stopping"].contains(state) }
    var title: String {
        ["preparing": "准备启动", "spawned": "进程已创建", "running": "窗口已建立", "stopping": "正在关闭", "exited": "已结束", "failed": "启动失败", "interrupted": "请求中断", "unconfirmed": "旧会话状态未确认", "orphaned": "旧进程仍占用容器"][state] ?? state
    }
}

struct LCGuestSessionView: View {
    @ObservedObject var model: LCAppModel
    @State private var sessions: [LCGuestSession] = []
    private let changes = NotificationCenter.default.publisher(for: Notification.Name("IOSVMProcessesDidChange"))

    var body: some View {
        List {
            Section {
                LCToolContext(model: model, title: "运行状态与授权", subtitle: "每次独立窗口启动都有一份进程和权限记录。", symbol: "app.connected.to.app.below.fill")
            }
            if sessions.isEmpty {
                Section {
                    LCToolEmptyState(title: "还没有启动记录", message: "使用独立测试窗口打开 App 后，可在这里查看进程、文件授权并关闭窗口。", symbol: "clock")
                }
            }
            ForEach(sessions, id: \.id) { session in
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(session.title).font(.headline)
                        Spacer(minLength: 8)
                        if let pid = session.value["pid"] as? Int, pid > 0 {
                            Text("PID " + String(pid)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                    if let timestamp = session.value["startedAt"] as? Double {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("启动时间").font(.caption).foregroundStyle(.secondary)
                            Text(Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 3)
                    }
                    if let reason = session.value["reason"] as? String {
                        Text(reason).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let error = session.value["journalError"] as? String { Text(error).foregroundStyle(.red) }
                    authorization(session)
                    DisclosureGroup("进程标识") {
                        LCPathDetail(title: "数据容器", path: session.value["container"] as? String ?? "")
                        LCPathDetail(title: "启动 UUID", path: session.id)
                    }.font(.subheadline)
                    if session.active {
                        Button(role: .destructive) {
                            NotificationCenter.default.post(name: Notification.Name("IOSVMStopGuest"), object: nil, userInfo: ["id": session.id])
                        } label: {
                            Label(session.state == "stopping" ? "正在关闭…" : "关闭这个测试进程", systemImage: "stop.circle")
                        }.disabled(session.state == "stopping")
                    }
                } header: {
                    if session.id == sessions.first?.id { Text("最近一次启动") }
                    else { Text("历史启动") }
                }
            }
            Section {
                DisclosureGroup("状态与权限说明") {
                    Text("窗口已建立不代表业务页面可用。Frida 断开本身不表示 App 已退出；全屏兼容运行不在此记录范围内。")
                    Text("数据容器可读写；程序、选中插件和配置通过系统文件令牌签发只读授权。兼容模式或系统共享容器的已有权限可能更广。清单不会额外获得 iOS 系统权限。")
                }.font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("运行状态与授权")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onReceive(changes) { _ in reload() }
        .refreshable { reload() }
        .toolbar { Button(action: reload) { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新运行记录") }
    }

    private func authorization(_ session: LCGuestSession) -> some View {
        let mode = session.value["authorizationMode"] as? String ?? ""
        let capabilities = session.value["capabilities"] as? [[String: Any]] ?? []
        return DisclosureGroup {
            HStack {
                Text("授权模式")
                Spacer()
                Text(mode == "scoped" ? "按目标授权" : (mode.isEmpty ? "尚未建立" : "兼容授权"))
                    .foregroundStyle(mode == "scoped" ? Color.secondary : Color.orange)
            }
            Text(session.value["authorizationConsumed"] as? Bool == true ? "已收到扩展授权回执" : "尚未收到扩展授权回执")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(capabilities.enumerated()), id: \.offset) { _, capability in
                DisclosureGroup {
                    Text(capability["path"] as? String ?? "").font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } label: {
                    HStack {
                        Text(role(capability["role"] as? String ?? ""))
                        Spacer()
                        Text(access(capability["access"] as? String ?? "")).foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack {
                Text("文件授权")
                Spacer()
                Text("\(capabilities.count) 项").foregroundStyle(.secondary)
            }
        }.font(.subheadline)
    }

    private func reload() {
        sessions = IOSVMProcessRegistry.shared.records(forBundle: model.appInfo.relativeBundlePath).compactMap { value in
            guard let record = value as? [String: Any] else { return nil }
            return LCGuestSession(value: record)
        }
    }
    private func role(_ name: String) -> String {
        ["application": "目标程序", "data": "目标沙盒", "selectedPlugins": "选中的插件目录", "globalPlugin": "全局插件", "networkSettings": "此 App 的网络配置", "legacyDocuments": "宿主 Documents", "legacyTweaks": "完整插件目录", "sharedApplication": "共享程序目录", "sharedData": "系统共享数据容器"][name] ?? name
    }
    private func access(_ name: String) -> String {
        ["readOnly": "只读", "readWrite": "读写", "systemSharedContainer": "系统共享"][name] ?? name
    }
}
