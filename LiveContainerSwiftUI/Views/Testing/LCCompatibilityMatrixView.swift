#if IOSVM_TESTING
import SwiftUI

private struct LCCompatibilityMatrixEntry: Decodable, Identifiable {
    let name: String
    let version: String
    let bundle: String
    let framework: String
    let encrypted: Bool?
    let architecture: String
    let minimumOS: String
    let extensions: Int
    let staticStatus: String
    let runtimeStatus: String
    let runtimeNotes: String
    let file: String
    let error: String

    var id: String {
        [bundle, version, file].joined(separator: "|")
    }
}

private struct LCCompatibilityMatrixDocument: Decodable {
    let generated: String
    let scannedFiles: Int
    let uniqueIPAs: Int
    let items: [LCCompatibilityMatrixEntry]
}

struct LCCompatibilityMatrixView: View {
    @State private var document: LCCompatibilityMatrixDocument?
    @State private var query = ""
    @State private var filter = "all"
    @State private var errorMessage: String?

    private var filtered: [LCCompatibilityMatrixEntry] {
        let items = document?.items ?? []
        return items.filter { item in
            let matchesFilter: Bool
            switch filter {
            case "runtime-pass": matchesFilter = item.runtimeStatus == "launch-pass"
            case "runtime-fail": matchesFilter = ["mixed", "launch-fail", "launch-partial"].contains(item.runtimeStatus)
            case "untested": matchesFilter = item.runtimeStatus == "not-tested"
            case "blocked": matchesFilter = item.staticStatus == "blocked" || item.staticStatus == "error"
            default: matchesFilter = true
            }
            guard matchesFilter else { return false }
            return query.isEmpty
                || item.name.localizedCaseInsensitiveContains(query)
                || item.bundle.localizedCaseInsensitiveContains(query)
                || item.version.localizedCaseInsensitiveContains(query)
                || item.framework.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if let document {
                Section {
                    LCToolContextContent(
                        title: "IPA 兼容性矩阵",
                        subtitle: "静态扫描 \(document.scannedFiles) 个文件，按内容去重后 \(document.uniqueIPAs) 个 IPA。",
                        symbol: "tablecells"
                    )
                    Text("生成日期：\(document.generated)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker("筛选", selection: $filter) {
                        Text("全部").tag("all")
                        Text("真机通过").tag("runtime-pass")
                        Text("失败/部分").tag("runtime-fail")
                        Text("待真机").tag("untested")
                        Text("静态阻断").tag("blocked")
                    }
                    .pickerStyle(.menu)
                }
                Section {
                    if filtered.isEmpty {
                        LCToolEmptyState(
                            title: "没有匹配结果",
                            message: "调整版本、Bundle ID、框架类型或运行状态筛选。",
                            symbol: "magnifyingglass"
                        )
                    }
                    ForEach(filtered) { item in
                        NavigationLink {
                            LCCompatibilityMatrixDetail(item: item)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: frameworkSymbol(item.framework))
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 36, height: 36)
                                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name).font(.body.weight(.medium)).lineLimit(2)
                                    Text((item.version.isEmpty ? "版本未知" : item.version) + " · " + item.framework)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    HStack(spacing: 8) {
                                        LCStatusTag(
                                            text: runtimeLabel(item.runtimeStatus),
                                            tone: runtimeTone(item.runtimeStatus)
                                        )
                                        if item.encrypted == true {
                                            Text("仍加密").font(.caption2).foregroundStyle(.red)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                } header: {
                    Text("结果 · \(filtered.count)")
                } footer: {
                    Text("“静态通过”只表示包结构和架构满足继续测试条件；只有 runtime-status 才代表真机启动证据。")
                }
            } else if let errorMessage {
                LCToolEmptyState(title: "矩阵读取失败", message: errorMessage, symbol: "exclamationmark.triangle")
            } else {
                ProgressView("正在读取矩阵…")
            }
        }
        .searchable(text: $query, prompt: "搜索 App、版本、Bundle ID 或框架")
        .navigationTitle("IPA 兼容性矩阵")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        guard document == nil else { return }
        do {
            guard let url = Bundle.main.url(forResource: "CompatibilityMatrix", withExtension: "json") else {
                throw "正式包未包含兼容性矩阵。"
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 2 * 1024 * 1024 else { throw "兼容性矩阵超过大小限制。" }
            document = try JSONDecoder().decode(LCCompatibilityMatrixDocument.self, from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runtimeLabel(_ value: String) -> String {
        [
            "launch-pass": "真机通过",
            "launch-partial": "部分通过",
            "launch-fail": "启动失败",
            "mixed": "结果冲突",
            "not-tested": "待真机"
        ][value] ?? value
    }

    private func runtimeTone(_ value: String) -> LCStatusTone {
        switch value {
        case "launch-pass": return .success
        case "launch-partial": return .warning
        case "launch-fail": return .error
        case "mixed": return .warning
        default: return .neutral
        }
    }

    private func frameworkSymbol(_ value: String) -> String {
        if value.contains("Flutter") { return "rectangle.3.group" }
        if value.contains("React") { return "circle.grid.cross" }
        if value.contains("Web") { return "safari" }
        return "app"
    }
}

private struct LCCompatibilityMatrixDetail: View {
    let item: LCCompatibilityMatrixEntry

    var body: some View {
        List {
            Section("应用") {
                value("名称", item.name)
                value("版本", item.version.isEmpty ? "未知" : item.version)
                value("Bundle ID", item.bundle.isEmpty ? "未知" : item.bundle)
                value("框架特征", item.framework)
            }
            Section("静态检查") {
                value("状态", item.staticStatus)
                value("加密", item.encrypted == true ? "仍加密" : (item.encrypted == false ? "未加密" : "未知"))
                value("架构", item.architecture.isEmpty ? "未知" : item.architecture)
                value("最低 iOS", item.minimumOS.isEmpty ? "未知" : item.minimumOS)
                value("扩展", String(item.extensions))
                if !item.error.isEmpty {
                    Text(item.error).foregroundStyle(.red)
                }
            }
            Section("真机结果") {
                value("状态", item.runtimeStatus)
                if !item.runtimeNotes.isEmpty {
                    Text(item.runtimeNotes).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("该版本尚未纳入真机运行矩阵。").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section("来源") {
                Text(item.file).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func value(_ title: String, _ content: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(content)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct LCToolContextContent: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
    }
}

#endif
