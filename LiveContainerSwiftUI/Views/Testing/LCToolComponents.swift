import SwiftUI

enum LCStatusTone {
    case neutral
    case info
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Shared hierarchy for the per-app tools. System colors and text styles follow accessibility settings.
struct LCToolContext: View {
    @ObservedObject var model: LCAppModel
    let title: String
    let subtitle: String
    let symbol: String

    private var status: (text: String, active: Bool) {
        if model.isOperationBusy || model.isLaunchPreparationBusy { return ("处理中", false) }
        let records = IOSVMProcessRegistry.shared.records(forBundle: model.appInfo.relativeBundlePath)
        for value in records {
            guard let record = value as? [String: Any], let state = record["state"] as? String else { continue }
            if let text = ["preparing": "准备启动", "spawned": "进程已创建", "running": "运行中", "stopping": "正在关闭", "orphaned": "旧进程仍占用"][state] {
                return (text, state == "running")
            }
        }
        return ("未运行", false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(model.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 8)
                LCStatusTag(text: status.text, active: status.active)
            }
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct LCStatusTag: View {
    let text: String
    let tone: LCStatusTone

    init(text: String, active: Bool = false) {
        self.text = text
        tone = active ? .success : .neutral
    }

    init(text: String, tone: LCStatusTone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 5) {
            if tone != .neutral { Circle().fill(tone.color).frame(width: 5, height: 5) }
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct LCToolRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var accessory: String? = nil
    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: symbol).font(.body.weight(.medium)).foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body).foregroundStyle(Color.primary)
                Text(subtitle).font(.caption).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let accessory {
                Spacer(minLength: 8)
                Image(systemName: accessory).font(.subheadline).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .frame(minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct LCToolEmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                .padding(.bottom, 4).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.vertical, 26)
    }
}

struct LCPathDetail: View {
    let title: String
    let path: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
    }
}

/// Compact identity for analysis pages: leave screen space for the evidence.
struct LCAnalysisContext: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 2)
    }
}

struct LCAnalysisCopyFeedback: ViewModifier {
    @Binding var copied: Bool
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if copied {
                Label("已复制", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium)).padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 20)
                    .allowsHitTesting(false)
            }
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 1_500_000_000); copied = false } catch {}
        }
    }
}

/// Search shows matching lines without changing the original text used for copying.
struct LCAnalysisTextContent: View {
    let text: String
    var query = ""
    var wraps = true
    private var matches: [(Int, String)] {
        text.components(separatedBy: "\n").enumerated().compactMap {
            $0.element.localizedCaseInsensitiveContains(query) ? ($0.offset + 1, $0.element) : nil
        }
    }
    var body: some View {
        Group {
            if query.isEmpty {
                code(text.isEmpty ? "（空内容）" : text)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("匹配 \(matches.count) 行 · 显示当前内容行号").font(.caption).foregroundStyle(.secondary)
                    if matches.isEmpty { Text("没有匹配内容").font(.subheadline).foregroundStyle(.secondary) }
                    else { code(matches.map { "\($0.0)  \($0.1)" }.joined(separator: "\n")) }
                }
            }
        }
    }
    @ViewBuilder private func code(_ value: String) -> some View {
        if wraps {
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal) {
                Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}
