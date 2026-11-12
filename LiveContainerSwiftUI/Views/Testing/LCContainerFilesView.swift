import SwiftUI
import UIKit
import QuickLook
import SQLite3

private struct LCExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct LCContainerFilesView: View {
    let root: URL
    let directory: URL
    @State private var entries: [LCFileEntry] = []
    @State private var query = ""
    @State private var sort = "name"
    @State private var copied = false
    @State private var errorMessage: String?
    @State private var loadError: String?
    @State private var loaded = false
    @State private var exporting = false
    @State private var exportItem: LCExportItem?
    @State private var exportWorkspace: URL?

    private var filtered: [LCFileEntry] {
        entries.filter { query.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(query) }.sorted {
            if ($0.type == .typeDirectory) != ($1.type == .typeDirectory) { return $0.type == .typeDirectory }
            if sort == "date", $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            if sort == "size", $0.size != $1.size { return $0.size > $1.size }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
    private var relativePath: String {
        let path = directory.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path == base ? "/" : String(path.dropFirst(base.count))
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("当前位置").font(.caption).foregroundStyle(.secondary)
                        Text(relativePath == "/" ? "沙盒根目录" : relativePath)
                            .font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer()
                    Button { UIPasteboard.general.string = directory.path; copied = true } label: { Image(systemName: "doc.on.doc").frame(width: 44, height: 44) }
                        .buttonStyle(.borderless).accessibilityLabel("复制目录路径")
                }
                HStack {
                    Text("\(filtered.count) / \(entries.count) 项").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Picker("排序", selection: $sort) {
                        Text("名称").tag("name")
                        Text("最近修改").tag("date")
                        Text("文件大小").tag("size")
                    }.pickerStyle(.menu).labelsHidden().accessibilityLabel("文件排序").font(.caption)
                }
            }
            Section {
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("重试") { reload() }
                } else if !loaded {
                    ProgressView()
                } else if filtered.isEmpty {
                    LCToolEmptyState(title: query.isEmpty ? "目录为空" : "没有匹配的文件", message: query.isEmpty ? "这个目录还没有文件。可返回上一级查看其他内容。" : "尝试其他文件名，或清除搜索条件。", symbol: "folder")
                }
                ForEach(filtered) { entry in
                    if entry.type == .typeDirectory {
                        NavigationLink { LCContainerFilesView(root: root, directory: entry.url) } label: { row(entry) }
                            .contextMenu { fileActions(entry) }
                    } else if entry.type == .typeRegular {
                        NavigationLink { LCContainerFilePreview(root: root, url: entry.url) } label: { row(entry) }
                            .contextMenu { fileActions(entry) }
                    } else {
                        row(entry).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("导出包含子目录，不跟随符号链接。为确保数据库完整，导出前请停止 App。")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索当前目录")
        .modifier(LCAnalysisCopyFeedback(copied: $copied))
        .navigationTitle(directory == root ? "浏览沙盒" : directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if exporting { ProgressView() }
                else {
                    Button { Task { await exportDirectory() } } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("导出当前目录 ZIP").disabled(loadError != nil || !loaded)
                }
            }
        }
        .task { reload() }
        .refreshable { reload() }
        .sheet(item: $exportItem, onDismiss: cleanupExport) { item in LCContainerShareSheet(url: item.url) }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确定") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private func fileActions(_ entry: LCFileEntry) -> some View {
        Button { UIPasteboard.general.string = entry.url.lastPathComponent; copied = true } label: { Label("复制名称", systemImage: "doc.on.doc") }
        Button { UIPasteboard.general.string = entry.url.path; copied = true } label: { Label("复制完整路径", systemImage: "folder") }
    }

    private func row(_ entry: LCFileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.type == .typeDirectory ? "folder.fill" : entry.type == .typeRegular ? "doc" : "link")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(entry.type == .typeDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 36, height: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.url.lastPathComponent).lineLimit(2)
                HStack {
                    if entry.type == .typeRegular { Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)) }
                    if let modified = entry.modified { Text(modified, style: .date); Text(modified, style: .time) }
                    if entry.type != .typeDirectory && entry.type != .typeRegular { Text("链接或特殊文件，未跟随") }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }

    private func reload() {
        do {
            try LCFileEntry.validate(directory, root: root)
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .map { try LCFileEntry(url: $0) }.sorted {
                    if ($0.type == .typeDirectory) != ($1.type == .typeDirectory) { return $0.type == .typeDirectory }
                    return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                }
            loadError = nil
        } catch { entries = []; loadError = error.localizedDescription }
        loaded = true
    }

    @MainActor private func exportDirectory() async {
        exporting = true
        defer { exporting = false }
        do {
            try LCFileEntry.validate(directory, root: root)
            let source = directory
            let url = try await Task.detached(priority: .userInitiated) { try LCContainerExport.archive(source: source) }.value
            cleanupExport()
            exportWorkspace = url.deletingLastPathComponent()
            exportItem = LCExportItem(url: url)
        } catch { errorMessage = error.localizedDescription }
    }

    private func cleanupExport() {
        if let exportWorkspace { try? FileManager.default.removeItem(at: exportWorkspace) }
        exportWorkspace = nil
    }
}

private struct LCFileEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let type: FileAttributeType
    let size: Int64
    let modified: Date?
    init(url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        self.url = url
        type = attrs[.type] as? FileAttributeType ?? .typeUnknown
        size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        modified = attrs[.modificationDate] as? Date
    }
    static func validate(_ url: URL, root: URL) throws {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path == base || path.hasPrefix(base + "/") else { throw "文件链接指向此沙盒以外，无法打开。" }
    }
}

struct LCContainerFilePreview: View {
    let root: URL
    let url: URL
    @State private var content = "正在读取…"
    @State private var tables: [String] = []
    @State private var isDatabase = false
    @State private var share = false
    @State private var quickLook = false
    @State private var readable = false
    @State private var query = ""
    @State private var wraps = true
    @State private var original: String?
    @State private var showOriginal = false
    @State private var copied = false

    var body: some View {
        Group {
            if isDatabase {
                List {
                    Section {
                        ForEach(tables.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { table in
                            NavigationLink(table) { LCSQLiteTableView(root: root, url: url, table: table) }
                        }
                        if tables.isEmpty { Text(content) }
                    } header: { Text("SQLite 数据表（只读）") }
                }
            } else {
                List {
                    Section {
                        LCAnalysisContext(title: url.lastPathComponent, detail: "只读预览 · 最多读取 512 KiB · 搜索不改变复制内容")
                        if original != nil {
                            Toggle("显示原文", isOn: $showOriginal)
                        }
                    }
                    Section {
                        LCAnalysisTextContent(text: showOriginal ? (original ?? content) : content, query: query, wraps: wraps)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle(url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: isDatabase ? "搜索数据表" : "查找文件内容")
        .modifier(LCAnalysisCopyFeedback(copied: $copied))
        .toolbar {
            if !isDatabase {
                Menu {
                    Button { UIPasteboard.general.string = showOriginal ? (original ?? content) : content; copied = true } label: { Label("复制预览内容", systemImage: "doc.on.doc") }
                    Toggle("自动换行", isOn: $wraps)
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("预览操作")
            }
            Button { quickLook = true } label: { Image(systemName: "eye") }.accessibilityLabel("系统预览").disabled(!readable)
            Button { share = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("导出文件").disabled(!readable)
        }
        .sheet(isPresented: $share) { LCContainerShareSheet(url: url) }
        .sheet(isPresented: $quickLook) { LCQuickLook(url: url) }
        .task { load() }
    }

    private func load() {
        do {
            try LCFileEntry.validate(url, root: root)
            guard try LCFileEntry(url: url).type == .typeRegular else { throw "该文件已移动或变成链接，请刷新目录。" }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let limit = 512 * 1024
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            readable = true
            original = String(data: data.prefix(limit), encoding: .utf8)
            if data.prefix(16) == Data("SQLite format 3\0".utf8) {
                isDatabase = true
                tables = try LCSQLitePreview.tables(url)
                content = "数据库中没有可浏览的数据表。"
                return
            }
            if data.count <= limit, let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                content = String(decoding: xml, as: UTF8.self)
            } else if data.count <= limit, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                      let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
                content = String(decoding: pretty, as: UTF8.self)
            } else if !data.prefix(limit).contains(0), let text = String(data: data.prefix(limit), encoding: .utf8) {
                content = text
            } else {
                content = "二进制文件，可通过上方眼睛按钮查看图片、PDF 等支持的格式。\n\n前 4096 字节：\n" + data.prefix(4096).enumerated().map {
                    ($0.offset % 16 == 0 ? String(format: "\n%08x  ", $0.offset) : " ") + String(format: "%02x", $0.element)
                }.joined()
            }
            if data.count > limit { content += "\n\n[文本仅预览前 512 KiB；导出可获取完整文件]" }
        } catch { content = error.localizedDescription }
    }
}

private enum LCSQLitePreview {
    static func query(_ url: URL, sql: String) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "打开失败"
            if let db { sqlite3_close(db) }
            throw "无法只读打开 SQLite：" + message
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw String(cString: sqlite3_errmsg(db)) }
        defer { sqlite3_finalize(statement) }
        var rows = [[String]]()
        var header = [String]()
        for column in 0..<sqlite3_column_count(statement) { header.append(String(cString: sqlite3_column_name(statement, column))) }
        rows.append(header)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw String(cString: sqlite3_errmsg(db)) }
            var row = [String]()
            for column in 0..<sqlite3_column_count(statement) {
                if sqlite3_column_type(statement, column) == SQLITE_NULL { row.append("NULL") }
                else if sqlite3_column_type(statement, column) == SQLITE_BLOB { row.append("[BLOB \(sqlite3_column_bytes(statement, column)) bytes]") }
                else if let text = sqlite3_column_text(statement, column) {
                    let count = min(Int(sqlite3_column_bytes(statement, column)), 1024)
                    row.append(String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self))
                } else { row.append("") }
            }
            rows.append(row)
        }
        return rows
    }
    static func tables(_ url: URL) throws -> [String] {
        try query(url, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name LIMIT 500").dropFirst().compactMap { $0.first }
    }
}

struct LCSQLiteTableView: View {
    let root: URL
    let url: URL
    let table: String
    @State private var rows = [[String]]()
    @State private var error: String?
    @State private var query = ""
    @State private var layout = "records"
    private var visibleIndices: [Int] {
        rows.indices.dropFirst().filter { index in query.isEmpty || rows[index].contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    private func columnWidth(_ column: Int) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let width = rows.map { column < $0.count ? ($0[column] as NSString).size(withAttributes: [.font: font]).width : 0 }.max() ?? 60
        return min(280, max(80, width + 16))
    }
    var body: some View {
        List {
            Section {
                Picker("浏览方式", selection: $layout) {
                    Text("记录").tag("records")
                    Text("表格").tag("grid")
                }.pickerStyle(.segmented)
                Text("\(visibleIndices.count) / \(max(0, rows.count - 1)) 条 · \(rows.first?.count ?? 0) 个字段")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } footer: {
                Text("只读展示前 100 行，每格最多 1024 字节。搜索仅针对已读取记录；点开记录查看各字段。")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if !rows.isEmpty && visibleIndices.isEmpty {
                LCToolEmptyState(title: query.isEmpty ? "表中没有记录" : "没有匹配记录", message: "仅检索当前预览的前 100 行。", symbol: "tablecells")
            }
            if layout == "records" {
                ForEach(visibleIndices, id: \.self) { index in
                    NavigationLink { LCSQLiteRecordView(columns: rows[0], values: rows[index], index: index) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("记录 \(index)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(Array(rows[0].indices.prefix(3)), id: \.self) { column in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(rows[0][column]).font(.caption).foregroundStyle(.secondary)
                                    Spacer(minLength: 8)
                                    Text(rows[index][column]).font(.system(.caption, design: .monospaced))
                                        .lineLimit(2).multilineTextAlignment(.trailing)
                                }
                            }
                        }.padding(.vertical, 5)
                    }
                }
            } else if let columns = rows.first {
                Section {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            gridRow(columns, header: true)
                            ForEach(visibleIndices, id: \.self) { index in
                                NavigationLink { LCSQLiteRecordView(columns: columns, values: rows[index], index: index) } label: {
                                    gridRow(rows[index], header: false)
                                }.buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(table).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索前 100 行记录")
        .task {
            do {
                try LCFileEntry.validate(url, root: root)
                let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
                rows = try LCSQLitePreview.query(url, sql: "SELECT * FROM \"\(quoted)\" LIMIT 100")
            } catch { self.error = error.localizedDescription }
        }
    }
    private func gridRow(_ values: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(values.indices, id: \.self) { column in
                Text(values[column]).font(.system(.caption, design: .monospaced))
                    .fontWeight(header ? .semibold : .regular).lineLimit(header ? 2 : 3)
                    .frame(width: columnWidth(column), alignment: .leading)
            }
        }.padding(.vertical, 12).padding(.horizontal, 8)
            .background(header ? Color(uiColor: .tertiarySystemGroupedBackground) : .clear)
    }
}

private struct LCSQLiteRecordView: View {
    let columns: [String]
    let values: [String]
    let index: Int
    @State private var copied = false
    var body: some View {
        List {
            Section {
                ForEach(columns.indices, id: \.self) { column in
                    HStack(alignment: .top) {
                        LCPathDetail(title: columns[column], path: values[column]).frame(maxWidth: .infinity, alignment: .leading)
                        Button { UIPasteboard.general.string = values[column]; copied = true } label: {
                            Image(systemName: "doc.on.doc").frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.borderless).accessibilityLabel("复制 " + columns[column])
                    }
                }
            } footer: { Text("显示预览读取到的字段值，每格最多 1024 字节；BLOB 仅显示大小。") }
        }
        .navigationTitle("记录 \(index)").navigationBarTitleDisplayMode(.inline)
        .modifier(LCAnalysisCopyFeedback(copied: $copied))
    }
}

private struct LCQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private struct LCContainerShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
