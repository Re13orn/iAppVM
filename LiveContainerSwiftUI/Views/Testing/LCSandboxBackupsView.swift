import SwiftUI

struct LCSandboxBackupsView: View {
    @ObservedObject var model: LCAppModel
    @State private var selected: String
    @State private var backups: [LCSandboxBackupStore.Summary] = []
    @State private var busy = false
    @State private var message: String?
    @State private var name = ""
    @State private var naming = false
    @State private var pending = false
    @State private var problem: String?

    init(model: LCAppModel, container: String? = nil) {
        self.model = model
        _selected = State(initialValue: container ?? model.uiSelectedContainer?.folderName ?? model.uiContainers.first?.folderName ?? "")
    }
    private var container: LCContainer? { model.uiContainers.first { $0.folderName == selected } }
    private func title(_ c: LCContainer) -> String {
        c.name == c.folderName ? "沙盒 " + String((model.uiContainers.firstIndex(of: c) ?? 0) + 1) : c.name
    }
    var body: some View {
        List {
            Section {
                Picker("数据容器", selection: $selected) {
                    ForEach(model.uiContainers, id: \.folderName) { c in Text(title(c)).tag(c.folderName) }
                }.disabled(busy)
                Text(model.displayName).font(.caption).foregroundStyle(.secondary)
                if busy { ProgressView("正在处理文件…") }
            }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            }
            if pending {
                Section {
                    Text("上次恢复尚未整理完成，目标容器暂不可启动。")
                    Button("完成恢复整理") { Task { await recover() } }.disabled(busy)
                }
            }
            Section {
                Button { name = "测试前备份"; naming = true } label: {
                    Label("创建备份", systemImage: "plus.circle")
                }.disabled(busy || pending || problem != nil || container == nil)
            } footer: { Text("备份、比较和恢复均需先关闭目标 App。备份保存在容器外；每份最多 8 GiB、50,000 个条目。") }
            Section("已有备份") {
                if backups.isEmpty { Text("尚无备份").foregroundStyle(.secondary) }
                ForEach(backups) { backup in
                    if let container {
                        NavigationLink {
                            LCSandboxBackupDetailView(model: model, container: container, backup: backup)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(backup.name).font(.body.weight(.medium)).lineLimit(2)
                                Text(backup.created.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                                Text("\(backup.files) 个文件 · " + ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }.disabled(busy || pending)
                    }
                }
            }
            Section("备份范围") {
                Text("包含所选容器中的普通文件与目录，按内容摘要识别变化；不展示文件正文。")
                Text("不包含 Keychain、Secure Enclave、容器外 App Group、系统权限和云端数据。链接与特殊文件不跟随；容器管理信息及调试记录不参与备份。恢复时保留当前排除项，冲突时停止。")
                    .foregroundStyle(.secondary)
            }.font(.footnote)
        }
        .navigationTitle("沙盒备份与比较").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .task(id: selected) { await reload() }
        .onAppear { Task { await reload() } }
        .refreshable { await reload() }
        .alert("备份名称", isPresented: $naming) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await create() } }
        }
        .alert("沙盒备份", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
    @MainActor private func reload() async {
        guard !busy else { return }
        backups = []; problem = nil; pending = false
        guard let container else { problem = "请先创建或选择数据容器。"; return }
        do {
            let context = try LCSandboxBackupManager.context(model, container)
            pending = LCSandboxBackupStore.pending(context)
            busy = true; defer { busy = false }
            backups = try await Task.detached { try LCSandboxBackupStore.list(context) }.value
        } catch { problem = error.localizedDescription }
    }
    @MainActor private func create() async {
        guard !busy, let container else { return }; busy = true
        do {
            let title = name
            _ = try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.create($0, name: title) }
            message = "备份已保存。"
        } catch { message = error.localizedDescription }
        busy = false; await reload()
    }
    @MainActor private func recover() async {
        guard !busy, let container else { return }; busy = true
        do { try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.recover($0) } }
        catch { message = error.localizedDescription }
        busy = false; await reload()
    }
}

private struct LCSandboxBackupDetailView: View {
    @ObservedObject var model: LCAppModel
    @ObservedObject var container: LCContainer
    let backup: LCSandboxBackupStore.Summary
    @State private var comparison: LCSandboxBackupStore.Comparison?
    @State private var busy = false
    @State private var message: String?
    @State private var confirmingRestore = false
    @State private var confirmingDelete = false
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    private var containerTitle: String {
        container.name == container.folderName ? "沙盒 " + String((model.uiContainers.firstIndex(of: container) ?? 0) + 1) : container.name
    }
    private var changes: [LCSandboxBackupStore.Change] {
        (comparison?.changes ?? []).filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        List {
            Section {
                Text(model.displayName + " · " + containerTitle).font(.subheadline).foregroundStyle(.secondary)
                Text(backup.name).font(.headline)
                Text(backup.created.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                Text("\(backup.files) 个文件 · " + ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file))
                if busy { ProgressView("正在处理文件…") }
                Button { Task { await compare() } } label: { Label("与当前沙盒比较", systemImage: "arrow.left.arrow.right") }.disabled(busy)
            }
            if let comparison {
                Section {
                    HStack {
                        count("新增", comparison.added, .green)
                        Spacer(); count("修改", comparison.modified, .orange)
                        Spacer(); count("删除", comparison.deleted, .red)
                    }
                    Text("相对于这份备份，按内容、类型及权限比较当前沙盒；时间变化不单独计入。")
                        .font(.caption).foregroundStyle(.secondary)
                    if comparison.changes.isEmpty { Label("普通文件未发现变化", systemImage: "checkmark.circle") }
                }
                Section("变化明细") {
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(change.status).font(.caption.weight(.semibold))
                                    .foregroundStyle(change.status == "删除" ? .red : change.status == "新增" ? .green : .orange)
                                Text(change.after?.kind == "directory" || change.before?.kind == "directory" ? "目录" : "文件")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(change.path).font(.footnote.monospaced()).textSelection(.enabled)
                            if let old = change.before, let new = change.after, old.kind == "file", new.kind == "file" {
                                Text(ByteCountFormatter.string(fromByteCount: old.size, countStyle: .file) + " → " + ByteCountFormatter.string(fromByteCount: new.size, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 3)
                    }
                }
                if !comparison.skipped.isEmpty {
                    Section {
                        DisclosureGroup("未参与比较的路径（\(comparison.skipped.count)）") {
                            ForEach(comparison.skipped, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                    } footer: { Text("包括链接、特殊文件和容器管理信息。链接目标不会被读取或恢复。") }
                }
                Section {
                    Button("恢复到这份备份…", role: .destructive) { confirmingRestore = true }
                        .disabled(busy)
                } footer: { Text("恢复会替换普通文件、删除备份后新增的普通文件，并先自动保存恢复前备份。Keychain 等独立存储不会回退，可能与恢复后的文件状态不同。") }
            }
            Section { Button("删除这份备份…", role: .destructive) { confirmingDelete = true }.disabled(busy) }
        }
        .navigationTitle("备份详情").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .searchable(text: $query, prompt: "筛选变化路径")
        .task {
            #if IOSVM_TESTING
            if UserDefaults.standard.bool(forKey: "iosvmTestBackupDiff") { await compare() }
            #endif
        }
        .confirmationDialog("确认恢复所选容器？", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("确认恢复普通沙盒文件", role: .destructive) { Task { await restore() } }
            Button("取消", role: .cancel) {}
        } message: {
            if let comparison { Text("将「\(containerTitle)」恢复到「\(backup.name)」。当前新增 \(comparison.added)、修改 \(comparison.modified)、删除 \(comparison.deleted) 项将回到备份状态。将先创建恢复前备份；Keychain 和其他独立存储保持当前状态。") }
        }
        .confirmationDialog("删除这份备份？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除备份", role: .destructive) { Task { await delete() } }
            Button("取消", role: .cancel) {}
        } message: { Text("仅删除这份备份，不修改当前沙盒。") }
        .alert("沙盒备份", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
    private func count(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 4) { Text(value.formatted()).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(color); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    @MainActor private func compare() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { let id = backup.id; comparison = try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.compare(id, $0) } }
        catch { comparison = nil; message = error.localizedDescription }
    }
    @MainActor private func restore() async {
        guard !busy, let expected = comparison else { return }; busy = true; defer { busy = false }
        do {
            let id = backup.id
            let rescue = try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.restore(id, $0, expected: expected) }
            comparison = nil; message = "普通文件已恢复。恢复前状态保存在「" + rescue.name + "」。"
        } catch { comparison = nil; message = error.localizedDescription }
    }
    @MainActor private func delete() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let id = backup.id
            try await LCSandboxBackupManager.perform(model, container) { try LCSandboxBackupStore.delete(id, $0) }
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

#if IOSVM_TESTING
struct LCSandboxBackupAcceptanceDetail: View {
    @ObservedObject var model: LCAppModel
    var body: some View {
        if let container = model.uiSelectedContainer ?? model.uiContainers.first,
           let context = try? LCSandboxBackupManager.context(model, container),
           let backups = try? LCSandboxBackupStore.list(context),
           let backup = backups.first(where: { $0.reason == "manual" }) {
            LCSandboxBackupDetailView(model: model, container: container, backup: backup)
        } else { Text("Fixture unavailable") }
    }
}
#endif
