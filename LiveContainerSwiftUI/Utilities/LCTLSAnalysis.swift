import Foundation
import Security
import CryptoKit

struct LCTLSFinding: Identifiable {
    let id: String
    let kind: String
    let path: String
    let title: String
    let detail: String
    var certificate: LCTLSCertificate?
}

struct LCTLSCertificate {
    let subject: String
    let issuer: String
    let sha256: String
    let spkiSHA256: String?
    let notBefore: Date?
    let notAfter: Date?
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    init?(der: Data) {
        guard der.count <= 2 * 1024 * 1024, let cert = SecCertificateCreateWithData(nil, der as CFData),
              let root = try? LCTLSDER.node(der), root.tag == 0x30, root.end == der.count,
              let outer = try? LCTLSDER.children(root, in: der), let tbs = outer.first,
              let fields = try? LCTLSDER.children(tbs, in: der) else { return nil }
        let offset = fields.first?.tag == 0xa0 ? 1 : 0
        guard fields.count > offset + 5 else { return nil }
        subject = SecCertificateCopySubjectSummary(cert) as String? ?? "未命名证书"
        issuer = LCTLSDER.commonName(fields[offset + 2], in: der) ?? "无法解析签发者名称"
        sha256 = Self.digest(der)
        let spki = fields[offset + 5]
        spkiSHA256 = spki.tag == 0x30 ? Data(SHA256.hash(data: der.subdata(in: spki.start..<spki.end))).base64EncodedString() : nil
        let dates = (try? LCTLSDER.children(fields[offset + 3], in: der)) ?? []
        notBefore = dates.first.flatMap { LCTLSDER.date($0, in: der) }
        notAfter = dates.dropFirst().first.flatMap { LCTLSDER.date($0, in: der) }
    }
}

/// Bounded DER traversal: never interprets bytes as executable code or reads a key.
private enum LCTLSDER {
    struct Node { let tag: UInt8; let start: Int; let content: Int; let end: Int }
    static func node(_ data: Data, at index: Int = 0, limit: Int? = nil) throws -> Node {
        let end = limit ?? data.count
        guard index >= 0, end <= data.count, index < end - 1 else { throw failure() }
        var cursor = index + 1
        let first = Int(data[cursor]); cursor += 1
        var length = first
        if first & 0x80 != 0 {
            let count = first & 0x7f
            guard (1...4).contains(count), cursor <= end - count else { throw failure() }
            length = 0
            for _ in 0..<count { length = length * 256 + Int(data[cursor]); cursor += 1 }
        }
        guard length <= end - cursor else { throw failure() }
        return Node(tag: data[index], start: index, content: cursor, end: cursor + length)
    }
    static func children(_ parent: Node, in data: Data) throws -> [Node] {
        var result: [Node] = [], cursor = parent.content
        while cursor < parent.end {
            guard result.count < 2048 else { throw failure() }
            let next = try node(data, at: cursor, limit: parent.end)
            result.append(next); cursor = next.end
        }
        return result
    }
    static func commonName(_ node: Node, in data: Data) -> String? {
        for set in (try? children(node, in: data)) ?? [] {
            for pair in (try? children(set, in: data)) ?? [] {
                let values = (try? children(pair, in: data)) ?? []
                if values.count == 2, data.subdata(in: values[0].content..<values[0].end) == Data([0x55, 0x04, 0x03]) {
                    return String(data: data.subdata(in: values[1].content..<values[1].end), encoding: values[1].tag == 0x1e ? .utf16BigEndian : .utf8)
                }
            }
        }
        return nil
    }
    static func date(_ node: Node, in data: Data) -> Date? {
        guard node.tag == 0x17 || node.tag == 0x18,
              var text = String(data: data.subdata(in: node.content..<node.end), encoding: .ascii) else { return nil }
        if node.tag == 0x17 {
            guard let year = Int(text.prefix(2)) else { return nil }
            text = (year >= 50 ? "19" : "20") + text
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"; formatter.isLenient = false
        return formatter.date(from: text)
    }
    static func failure() -> NSError { NSError(domain: "LCTLSAnalysis", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效或过大的 DER 数据"]) }
}

enum LCTLSAnalysis {
    struct Report {
        var findings: [LCTLSFinding] = []
        var inspected = 0
        var skipped = 0
        var limited = false
    }
    // Public certificate resources only; PKCS#12 candidates are never unlocked/imported.
    static func scan(bundle: URL, cancelled: () -> Bool = { false }) throws -> Report {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey]
        let base = bundle.standardizedFileURL.resolvingSymlinksInPath()
        guard (try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isSymbolicLink != true else { throw LCTLSDER.failure() }
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { throw LCTLSDER.failure() }
        var report = Report(), visited = 0, bytes = 0
        for case let file as URL in walker {
            if cancelled() { throw CancellationError() }
            visited += 1
            if visited > 20000 || report.findings.count >= 1000 { report.limited = true; break }
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { walker.skipDescendants(); report.skipped += 1; continue }
            let name = file.lastPathComponent
            if ["_CodeSignature", "SC_Info"].contains(name) { walker.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let ext = file.pathExtension.lowercased()
            let relative = String(file.standardizedFileURL.path.dropFirst(base.path.count + 1))
            // Never classify mobileprovision/code-signing material as app TLS identity.
            guard ext != "mobileprovision" else { continue }
            if ["p12", "pfx"].contains(ext) {
                report.findings.append(.init(id: relative, kind: "identity-candidate", path: relative, title: "PKCS#12 候选", detail: "仅按扩展名发现，未解锁或验证内容。可能包含身份材料；存在不代表已用于 mTLS。"))
                continue
            }
            let certificateExtension = ["cer", "crt", "der", "pem"].contains(ext)
            let config = ext == "plist" || ext == "json"
            // Sniff small extensionless/binary resources, but never load executables wholesale.
            guard certificateExtension || config || (values.fileSize ?? 0) <= 64 * 1024 else { continue }
            guard (values.fileSize ?? 0) <= 2 * 1024 * 1024 else { report.skipped += 1; continue }
            let size = values.fileSize ?? 0
            if bytes + size > 32 * 1024 * 1024 { report.limited = true; break }
            guard file.standardizedFileURL.path.hasPrefix(base.path + "/"), file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
                  let handle = try? FileHandle(forReadingFrom: file) else { report.skipped += 1; continue }
            let data = (try? handle.read(upToCount: 2 * 1024 * 1024 + 1)) ?? Data(); try? handle.close()
            guard data.count <= 2 * 1024 * 1024 else { report.skipped += 1; continue }
            bytes += data.count; report.inspected += 1
            for (index, der) in certificates(data).enumerated() {
                if report.findings.count >= 1000 { report.limited = true; break }
                if let certificate = LCTLSCertificate(der: der) {
                    report.findings.append(.init(id: relative + "#" + String(index), kind: "certificate", path: relative, title: certificate.subject, detail: "已解析 X.509 公共证书；用途需结合配置与运行行为确认。", certificate: certificate))
                }
            }
            if config {
                let object = (try? PropertyListSerialization.propertyList(from: data, format: nil)) ?? (try? JSONSerialization.jsonObject(with: data))
                if let object { configurations(object, path: relative, trail: [], depth: 0, into: &report.findings) }
            }
        }
        return report
    }
    static func certificates(_ data: Data) -> [Data] {
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            return text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().prefix(64).compactMap {
                guard let block = $0.components(separatedBy: "-----END CERTIFICATE-----").first,
                      $0.contains("-----END CERTIFICATE-----") else { return nil }
                return Data(base64Encoded: block, options: .ignoreUnknownCharacters)
            }
        }
        return LCTLSCertificate(der: data) == nil ? [] : [data]
    }
    private static func configurations(_ object: Any, path: String, trail: [String], depth: Int, into findings: inout [LCTLSFinding]) {
        guard depth < 20, findings.count < 1000 else { return }
        if let dictionary = object as? [String: Any] {
            if let domains = dictionary["NSPinnedDomains"] as? [String: Any] {
                for domain in domains.keys.sorted() {
                    guard findings.count < 1000 else { break }
                    let detail = String(data: (try? JSONSerialization.data(withJSONObject: domains[domain]!, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])) ?? Data(), encoding: .utf8) ?? "无法展示配置"
                    findings.append(.init(id: path + ":" + (trail + ["NSPinnedDomains", domain]).joined(separator: "."), kind: path == "Info.plist" && trail == ["NSAppTransportSecurity"] ? "ats-pinning" : "pin-config-candidate", path: path, title: domain, detail: "发现 Pinning 配置内容；仅主 App Info.plist 的 NSAppTransportSecurity 是系统配置入口。不证明本次请求已执行。\n" + String(detail.prefix(16384))))
                }
            }
            if let domains = dictionary["TSKPinnedDomains"] as? [String: Any] {
                for domain in domains.keys.sorted().prefix(1000 - min(1000, findings.count)) {
                    findings.append(.init(id: path + ":" + (trail + ["TSKPinnedDomains", domain]).joined(separator: "."), kind: "library-config", path: path, title: domain, detail: "发现 TrustKit 配置线索；库是否初始化、规则是否执行需动态确认。"))
                }
            }
            for key in dictionary.keys.sorted() { configurations(dictionary[key]!, path: path, trail: trail + [key], depth: depth + 1, into: &findings) }
        } else if let array = object as? [Any] {
            for (i, value) in array.prefix(1000).enumerated() { configurations(value, path: path, trail: trail + [String(i)], depth: depth + 1, into: &findings) }
        }
    }
}
