import SwiftUI
import UIKit
import UniformTypeIdentifiers
import LocalAuthentication

struct LCAppDataToolsView: View {
    @ObservedObject var model: LCAppModel

    var body: some View {
        Form {
            Section {
                LCAnalysisContext(title: model.displayName, detail: "当前数据容器 · 文件、数据库与 Keychain")
            }
            Section {
                NavigationLink {
                    LCAppSandboxView(model: model)
                } label: {
                    LCToolRow(
                        title: "沙盒文件",
                        subtitle: "浏览目录、数据库、备份和文件差异",
                        symbol: "folder"
                    )
                }
                NavigationLink {
                    LCGuestKeychainView(model: model)
                } label: {
                    LCToolRow(
                        title: "Guest Keychain",
                        subtitle: "只读查看当前容器的服务、账户、类型和更新时间",
                        symbol: "key.fill"
                    )
                }
            } header: {
                Text("数据结构")
            } footer: {
                Text("Keychain 与普通沙盒文件分开保存；沙盒备份和恢复不会修改 Keychain。")
            }
            Section {
                NavigationLink { LCSandboxBackupsView(model: model) } label: {
                    LCToolRow(title: "备份与比较", subtitle: "保存文件基线，定位新增、修改和删除", symbol: "clock.arrow.circlepath")
                }
            } footer: { Text("包含 \(model.uiContainers.count) 个数据容器。沙盒恢复只影响普通文件，不回退 Keychain、系统权限或云端数据。") }
        }
        .navigationTitle("文件与 Keychain")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LCGuestKeychainView: View {
    @ObservedObject var model: LCAppModel
    @State private var selectedContainer = ""
    @State private var snapshot: LCGuestKeychainSnapshot?
    @State private var loading = false
    @State private var unlocking = false
    @State private var attemptedUnlock = false
    @State private var authenticationContext: LAContext?
    @State private var fridaIndex: LCFridaKeychainIndex?
    @State private var enablingFrida = false
    @State private var query = ""
    @State private var message: String?
    @State private var exportURL: URL?
    @State private var exportFolder: URL?
    @State private var sharing = false

    private var container: LCContainer? {
        model.uiContainers.first { $0.folderName == selectedContainer }
            ?? model.uiSelectedContainer
            ?? model.uiContainers.first
    }

    private var filteredItems: [LCGuestKeychainItem] {
        let items = mergedItems
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.service.localizedCaseInsensitiveContains(query)
                || $0.account.localizedCaseInsensitiveContains(query)
                || $0.itemClass.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    private var mergedItems: [LCGuestKeychainItem] {
        var items = snapshot?.items ?? []
        for item in fridaIndex?.items ?? [] {
            if !items.contains(where: {
                $0.itemClass == item.itemClass
                    && $0.service == item.service
                    && $0.account == item.account
                    && $0.label == item.label
            }) {
                items.append(item)
            }
        }
        return items
    }

    var body: some View {
        List {
            Section {
                LCAnalysisContext(title: model.displayName, detail: "当前容器的 Guest Keychain · 只读元数据，敏感值需验证身份")
            }

            if model.uiContainers.isEmpty {
                Section {
                    LCToolEmptyState(
                        title: "尚无数据容器",
                        message: "首次启动 App 后会分配 Guest Keychain 组，再回到这里查看。",
                        symbol: "lock.slash"
                    )
                }
            } else {
                Section {
                    Picker("数据容器", selection: $selectedContainer) {
                        ForEach(model.uiContainers, id: \.folderName) { item in
                            Text(containerName(item)).tag(item.folderName)
                        }
                    }
                    .onChange(of: selectedContainer) { _ in reload() }
                    if let snapshot {
                        HStack {
                            Text("Keychain 范围")
                            Spacer()
                            Text(snapshot.groupTitle).foregroundStyle(.secondary)
                        }
                        LCPathDetail(title: "访问组", path: snapshot.accessGroup)
                    }
                } header: {
                    Text("读取范围")
                } footer: {
                    Text("浏览器通过容器分配的唯一访问组查询，并在系统返回容器别名时再次核对。不会查询设备上其他 App 的 Keychain。")
                }

                if loading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("正在读取 Keychain 元数据…")
                            Spacer()
                        }
                    }
                } else if let snapshot {
                    if filteredItems.isEmpty {
                        Section {
                            LCToolEmptyState(
                                title: query.isEmpty ? "此容器没有 Keychain 条目" : "没有匹配的条目",
                                message: query.isEmpty ? "App 尚未写入 Keychain，或使用了当前签名范围之外的其他访问组。" : "尝试搜索服务名、账户、标签或条目类型。",
                                symbol: "lock.slash"
                            )
                        }
                    }
                    ForEach(LCGuestKeychainClass.allCases) { itemClass in
                        let items = filteredItems.filter { $0.itemClass == itemClass }
                        if !items.isEmpty {
                            Section {
                                ForEach(items, id: \.id) { item in
                                    NavigationLink {
                                        LCGuestKeychainDetailView(item: item, container: container ?? model.uiContainers[0])
                                    } label: {
                                        KeychainMetadataRow(item: item)
                                    }
                                }
                            } header: {
                                Label("\(itemClass.rawValue) · \(items.count)", systemImage: itemClass.symbol)
                            }
                        }
                    }
                    if !snapshot.warnings.isEmpty {
                        Section {
                            Button {
                                Task { await unlockAndRetry() }
                            } label: {
                                if unlocking {
                                    Label("正在验证身份…", systemImage: "lock.open")
                                } else {
                                    Label("验证身份并重新读取", systemImage: "lock.open")
                                }
                            }
                            .disabled(loading || unlocking)
                            ForEach(snapshot.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        } header: {
                            Text("部分 Keychain 类型未能读取").textCase(nil)
                        } footer: {
                            Text("如果项目受“解锁后可访问”保护，请先解锁 iPhone，再点击重新读取。同步条目已包含在查询中。")
                        }
                    }
                }

                Section {
                    if let fridaIndex {
                        HStack {
                            Label("已收到进程内扫描", systemImage: "ant.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Text("\(fridaIndex.items.count) 项").foregroundStyle(.secondary)
                        }
                        if !fridaIndex.warnings.isEmpty {
                            ForEach(fridaIndex.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        }
                        LCPathDetail(
                            title: "Frida 访问组",
                            path: fridaIndex.accessGroup
                        )
                    } else {
                        Text("目标尚未加载 Frida Keychain Inspector。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        enableFrida()
                    } label: {
                        if enablingFrida {
                            Label("正在配置…", systemImage: "hourglass")
                        } else {
                            Label("启用启动时进程内扫描", systemImage: "ant.fill")
                        }
                    }
                    .disabled(
                        enablingFrida
                            || model.isAppRunning
                            || !LCFridaSetup.enabled(model.appInfo)
                    )
                    NavigationLink {
                        LCFridaView(model: model)
                    } label: {
                        Label("打开 Frida 调试与脚本日志", systemImage: "terminal")
                    }
                } header: {
                    Text("Frida 进程内读取").textCase(nil)
                } footer: {
                    Text(LCFridaSetup.enabled(model.appInfo)
                        ? "启用后会添加内置 Keychain Inspector，并切换到“手机自动脚本”模式；关闭目标后保存，下次启动生效。默认只写元数据，密码值需在脚本中显式调用 authDump()。"
                        : "需先在 Frida 调试页启用 Gadget。进程内扫描可覆盖宿主在锁屏、访问控制和部分系统类型上的限制。")
                }
            }
        }
        .searchable(text: $query, prompt: "搜索服务、账户、标签或类型")
        .navigationTitle("Guest Keychain")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
                .accessibilityLabel("刷新 Keychain")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: exportMetadata) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(snapshot == nil || snapshot?.items.isEmpty != false)
                .accessibilityLabel("导出不含敏感值的 Keychain 索引")
            }
        }
        .onAppear {
            if selectedContainer.isEmpty {
                selectedContainer = model.uiSelectedContainer?.folderName ?? model.uiContainers.first?.folderName ?? ""
            }
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if snapshot?.warnings.isEmpty == false { reload() }
        }
        .refreshable { reload() }
        .onDisappear {
            cleanupExport()
            authenticationContext?.invalidate()
            authenticationContext = nil
        }
        .sheet(isPresented: $sharing, onDismiss: cleanupExport) {
            if let exportURL { ActivityViewController(activityItems: [exportURL]) }
        }
        .alert("Guest Keychain", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("确定") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func containerName(_ item: LCContainer) -> String {
        guard let index = model.uiContainers.firstIndex(of: item) else { return item.name }
        return item.name == item.folderName ? "沙盒 \(index + 1)" : item.name
    }

    private func reload() {
        guard let container else {
            snapshot = nil
            loading = false
            return
        }
        loading = true
        defer { loading = false }
        do {
            let value = try LCGuestKeychainBrowser.snapshot(
                for: container,
                authenticationContext: authenticationContext
            )
            snapshot = value
            fridaIndex = try LCFridaKeychainInspector.latestIndex(model: model, container: container)
            if !attemptedUnlock, value.warnings.contains(where: warningRequiresAuthentication) {
                attemptedUnlock = true
                Task { await unlockAndRetry() }
            }
        } catch {
            snapshot = nil
            message = error.localizedDescription
        }
    }

    @MainActor
    private func enableFrida() {
        enablingFrida = true
        defer { enablingFrida = false }
        do {
            try LCFridaKeychainInspector.enableForNextLaunch(model: model)
            message = "已加入内置 Keychain Inspector。请重新启动目标；扫描完成后再进入本页查看结果。"
        } catch {
            message = error.localizedDescription
        }
    }

    private func warningRequiresAuthentication(_ warning: String) -> Bool {
        warning.contains("系统拒绝访问")
            || warning.contains("设备当前锁定")
            || warning.contains("解锁 iPhone")
    }

    @MainActor
    private func unlockAndRetry() async {
        unlocking = true
        defer { unlocking = false }
        do {
            authenticationContext?.invalidate()
            authenticationContext = try await LCGuestKeychainBrowser.authorizeKeychainAccess()
            try await Task.sleep(nanoseconds: 350_000_000)
            reload()
        } catch {
            if let error = error as? LAError,
               [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                return
            }
            message = error.localizedDescription
        }
    }

    private func exportMetadata() {
        guard let snapshot, let container else { return }
        do {
            let folder = try LCManagedDirectory.temporaryWorkspace()
            cleanupExport()
            let file = folder.appendingPathComponent("Guest-Keychain-Index.json")
            let value: [String: Any] = [
                "warning": "仅包含 Keychain 元数据，不包含任何敏感值。",
                "app": model.displayName,
                "bundleIdentifier": model.bundleIdentifier,
                "container": container.folderName,
                "accessGroup": snapshot.accessGroup,
                "items": snapshot.items.map(LCGuestKeychainBrowser.metadataDictionary)
            ]
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            exportFolder = folder
            exportURL = file
            sharing = true
        } catch {
            message = error.localizedDescription
        }
    }

    private func cleanupExport() {
        if let exportFolder { LCManagedDirectory.cleanup(exportFolder) }
        exportFolder = nil
        exportURL = nil
    }
}

private struct KeychainMetadataRow: View {
    let item: LCGuestKeychainItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.itemClass.symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.body).lineLimit(2)
                if !item.service.isEmpty, item.service != item.title {
                    Text(item.service).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !item.account.isEmpty {
                    Text("账户：\(item.account)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(item.itemClass.rawValue)
                    if case .frida = item.source {
                        Text("Frida 进程内").foregroundStyle(Color.accentColor)
                    }
                    if let modified = item.modifiedAt {
                        Text(modified, style: .date)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct LCGuestKeychainDetailView: View {
    let item: LCGuestKeychainItem
    let container: LCContainer
    @Environment(\.scenePhase) private var scenePhase
    @State private var value: LCGuestKeychainValue?
    @State private var authorizing = false
    @State private var authenticationContext: LAContext?
    @State private var hideTask: Task<Void, Never>?
    @State private var message: String?
    @State private var exportURL: URL?
    @State private var exportFolder: URL?
    @State private var sharing = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: item.itemClass.symbol)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(item.itemClass.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                metadataRow("服务", item.service)
                metadataRow("账户", item.account)
                metadataRow("标签", item.label)
                if let created = item.createdAt {
                    HStack {
                        Text("创建时间")
                        Spacer()
                        Text(created.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                    }
                }
                if let modified = item.modifiedAt {
                    HStack {
                        Text("更新时间")
                        Spacer()
                        Text(modified.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                    }
                }
                LCPathDetail(title: "访问组", path: item.accessGroup)
            } header: {
                Text("元数据")
            }

            Section {
                if let value {
                    Text(value.displayText)
                        .font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .privacySensitive()
                    if let note = value.note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let copyText = value.copyText {
                        Button {
                            copySensitiveValue(copyText)
                        } label: {
                            Label("复制值（60 秒后失效）", systemImage: "doc.on.doc")
                        }
                    }
                    Button {
                        exportValue()
                    } label: {
                        Label("导出此项", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        resetHidden()
                    } label: {
                        Label("重新隐藏", systemImage: "eye.slash")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("敏感内容已隐藏", systemImage: "lock.shield")
                            .font(.headline)
                        Text("显示、复制或导出前需要设备密码、触控 ID 或面容 ID 验证。离开本页后内容会自动清除。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await reveal() }
                        } label: {
                            if authorizing {
                                Label("正在验证身份…", systemImage: "lock.open")
                            } else {
                                Label("验证并显示", systemImage: "lock.open")
                            }
                        }
                        .disabled(authorizing)
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                Text("敏感值与受保护内容")
            } footer: {
                Text("显示内容会在 30 秒后、离开本页或切到后台时自动隐藏。导出会生成包含可见内容的临时 JSON 文件；分享完成后临时文件会删除，但接收方副本不受 iAppVM 控制。")
            }
        }
        .navigationTitle("Keychain 条目")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            resetHidden()
            cleanupExport()
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { resetHidden() }
        }
        .sheet(isPresented: $sharing, onDismiss: cleanupExport) {
            if let exportURL { ActivityViewController(activityItems: [exportURL]) }
        }
        .alert("Guest Keychain", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("确定") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "未提供" : value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    @MainActor
    private func reveal() async {
        authorizing = true
        defer { authorizing = false }
        do {
            authenticationContext?.invalidate()
            authenticationContext = try await LCGuestKeychainBrowser.authorizeReveal()
            value = try LCGuestKeychainBrowser.reveal(
                item,
                in: container,
                authenticationContext: authenticationContext
            )
            scheduleAutoHide()
        } catch {
            if let error = error as? LAError,
               [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                return
            }
            message = error.localizedDescription
        }
    }

    private func copySensitiveValue(_ text: String) {
        let options: [UIPasteboard.OptionsKey: Any] = [
            .expirationDate: Date().addingTimeInterval(60)
        ]
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: options
        )
        resetHidden()
        message = "已复制，页面已重新隐藏；系统会在约 60 秒后清除剪贴板内容。"
    }

    private func exportValue() {
        guard let value else { return }
        do {
            let folder = try LCManagedDirectory.temporaryWorkspace()
            cleanupExport()
            let file = folder.appendingPathComponent("Guest-Keychain-Item.json")
            var payload = LCGuestKeychainBrowser.metadataDictionary(item)
            payload["warning"] = "包含用户主动显示的敏感内容"
            payload["value"] = value.exportText
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            exportFolder = folder
            exportURL = file
            resetHidden()
            sharing = true
        } catch {
            message = error.localizedDescription
        }
    }

    private func cleanupExport() {
        if let exportFolder { LCManagedDirectory.cleanup(exportFolder) }
        exportFolder = nil
        exportURL = nil
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            value = nil
            hideTask = nil
        }
    }

    private func resetHidden() {
        hideTask?.cancel()
        hideTask = nil
        value = nil
        authenticationContext?.invalidate()
        authenticationContext = nil
    }
}
