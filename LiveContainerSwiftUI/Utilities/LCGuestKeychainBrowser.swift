import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum LCGuestKeychainClass: String, CaseIterable, Identifiable {
    case genericPassword = "通用密码"
    case internetPassword = "互联网密码"
    case certificate = "证书"
    case key = "密钥"
    case identity = "身份"

    var id: String { rawValue }

    var securityClass: CFString {
        switch self {
        case .genericPassword: return kSecClassGenericPassword
        case .internetPassword: return kSecClassInternetPassword
        case .certificate: return kSecClassCertificate
        case .key: return kSecClassKey
        case .identity: return kSecClassIdentity
        }
    }

    var symbol: String {
        switch self {
        case .genericPassword: return "key.fill"
        case .internetPassword: return "network"
        case .certificate: return "checkmark.seal.fill"
        case .key: return "key.fill"
        case .identity: return "person.crop.rectangle"
        }
    }
}

struct LCGuestKeychainItem {
    enum Source {
        case host
        case frida
    }

    let id: String
    let itemClass: LCGuestKeychainClass
    let source: Source
    let service: String
    let account: String
    let label: String
    let createdAt: Date?
    let modifiedAt: Date?
    let persistentReference: Data?
    let attributes: [String: Any]

    var title: String {
        if !label.isEmpty { return label }
        if !service.isEmpty { return service }
        if !account.isEmpty { return account }
        return itemClass.rawValue
    }

    var accessGroup: String {
        attributes[kSecAttrAccessGroup as String] as? String ?? ""
    }

    var matchingAttributes: [String: Any] {
        let keys: [CFString] = [
            kSecAttrService,
            kSecAttrAccount,
            kSecAttrServer,
            kSecAttrProtocol,
            kSecAttrPort,
            kSecAttrPath,
            kSecAttrSecurityDomain,
            kSecAttrApplicationLabel,
            kSecAttrApplicationTag,
            kSecAttrSynchronizable
        ]
        var result: [String: Any] = [:]
        for key in keys {
            let name = key as String
            if let value = attributes[name] { result[name] = value }
        }
        return result
    }
}

struct LCGuestKeychainSnapshot {
    let accessGroup: String
    let keychainGroupID: Int
    let items: [LCGuestKeychainItem]
    let warnings: [String]

    var groupTitle: String {
        keychainGroupID == 0 ? "默认 Guest 组" : "Guest 组 \(keychainGroupID)"
    }
}

struct LCGuestKeychainValue {
    let displayText: String
    let exportText: String
    let copyText: String?
    let note: String?
}

enum LCGuestKeychainBrowser {
    static func accessGroup(for container: LCContainer) throws -> String {
        try scope(for: container).accessGroup
    }

    static func snapshot(for container: LCContainer, authenticationContext: LAContext? = nil) throws -> LCGuestKeychainSnapshot {
        let scope = try scope(for: container)
        var items: [LCGuestKeychainItem] = []
        var warnings: [String] = []

        for itemClass in LCGuestKeychainClass.allCases {
            do {
                items.append(contentsOf: try list(
                    itemClass,
                    scope: scope,
                    container: container,
                    authenticationContext: authenticationContext
                ))
            } catch {
                if let error = error as? LCGuestKeychainError, error.isMissingEntitlement {
                    throw error
                }
                warnings.append("\(itemClass.rawValue)：\(error.localizedDescription)")
            }
        }

        let order = Dictionary(uniqueKeysWithValues: LCGuestKeychainClass.allCases.enumerated().map { ($1, $0) })
        items.sort {
            if order[$0.itemClass] != order[$1.itemClass] { return (order[$0.itemClass] ?? 0) < (order[$1.itemClass] ?? 0) }
            return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
        }
        return LCGuestKeychainSnapshot(
            accessGroup: scope.accessGroup,
            keychainGroupID: scope.keychainGroupID,
            items: items,
            warnings: warnings
        )
    }

    static func reveal(
        _ item: LCGuestKeychainItem,
        in container: LCContainer,
        authenticationContext: LAContext? = nil
    ) throws -> LCGuestKeychainValue {
        let scope = try scope(for: container)
        guard item.accessGroup.isEmpty || item.accessGroup == scope.accessGroup else {
            throw LCGuestKeychainError.scope("条目不属于当前容器分配的 Keychain 组。")
        }

        switch item.itemClass {
        case .genericPassword, .internetPassword:
            let data = try copyData(item, scope: scope, authenticationContext: authenticationContext)
            guard data.count <= 1024 * 1024 else {
                throw LCGuestKeychainError.read("该值超过 1 MiB，浏览器不会读取或导出。")
            }
            let rendered = render(data)
            return LCGuestKeychainValue(
                displayText: rendered,
                exportText: rendered,
                copyText: rendered,
                note: data.isEmpty ? "该项保存的是空值。" : nil
            )
        case .certificate:
            let reference = try copyReference(item, scope: scope, authenticationContext: authenticationContext)
            guard CFGetTypeID(reference) == SecCertificateGetTypeID() else {
                throw LCGuestKeychainError.read("系统返回的证书引用无效。")
            }
            let certificate: SecCertificate = unsafeBitCast(reference, to: SecCertificate.self)
            let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "未命名证书"
            let data = SecCertificateCopyData(certificate) as Data
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let rendered = "主题：\(subject)\nSHA-256：\(fingerprint)"
            return LCGuestKeychainValue(
                displayText: rendered,
                exportText: rendered,
                copyText: fingerprint,
                note: "仅展示证书摘要与 SHA-256；不会导出私钥。"
            )
        case .key:
            let reference = try copyReference(item, scope: scope, authenticationContext: authenticationContext)
            guard CFGetTypeID(reference) == SecKeyGetTypeID() else {
                throw LCGuestKeychainError.read("系统返回的密钥引用无效。")
            }
            let key: SecKey = unsafeBitCast(reference, to: SecKey.self)
            let attributes = SecKeyCopyAttributes(key) as? [String: Any] ?? [:]
            let type = attributes[kSecAttrKeyType as String].map { String(describing: $0) } ?? "未知类型"
            let bits = attributes[kSecAttrKeySizeInBits as String].map { String(describing: $0) } ?? "未知长度"
            var fingerprint = "无法读取公钥摘要"
            if let publicKey = SecKeyCopyPublicKey(key),
               let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? {
                fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            let rendered = "类型：\(type)\n长度：\(bits) bit\n公钥 SHA-256：\(fingerprint)"
            return LCGuestKeychainValue(
                displayText: rendered,
                exportText: rendered,
                copyText: fingerprint,
                note: "私钥材料由系统安全模块保护，浏览器不能导出。"
            )
        case .identity:
            let reference = try copyReference(item, scope: scope, authenticationContext: authenticationContext)
            guard CFGetTypeID(reference) == SecIdentityGetTypeID() else {
                throw LCGuestKeychainError.read("系统返回的身份引用无效。")
            }
            let identity: SecIdentity = unsafeBitCast(reference, to: SecIdentity.self)
            var certificate: SecCertificate?
            let status = SecIdentityCopyCertificate(identity, &certificate)
            guard status == errSecSuccess, let certificate else {
                throw error("无法读取身份中的证书", status: status)
            }
            let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "未命名身份证书"
            let data = SecCertificateCopyData(certificate) as Data
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let rendered = "身份：\(subject)\n证书 SHA-256：\(fingerprint)"
            return LCGuestKeychainValue(
                displayText: rendered,
                exportText: rendered,
                copyText: fingerprint,
                note: "不会导出身份关联的私钥。"
            )
        }
    }

    @MainActor
    static func authorizeReveal() async throws -> LAContext {
        try await authorize(reason: "验证身份后显示当前 Guest 的 Keychain 数据")
    }

    @MainActor
    static func authorizeKeychainAccess() async throws -> LAContext {
        try await authorize(reason: "验证身份并解锁当前 Guest 的 Keychain 元数据")
    }

    @MainActor
    private static func authorize(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        context.localizedFallbackTitle = "使用设备密码"
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw LCGuestKeychainError.auth(policyError?.localizedDescription ?? "设备未设置密码或认证不可用。")
        }
        let success: Bool = try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
        guard success else { throw LCGuestKeychainError.auth("身份验证未通过。") }
        return context
    }

    static func metadataDictionary(_ item: LCGuestKeychainItem) -> [String: Any] {
        var value: [String: Any] = [
            "type": item.itemClass.rawValue,
            "service": item.service,
            "account": item.account,
            "label": item.label,
            "accessGroup": item.accessGroup
        ]
        if let createdAt = item.createdAt { value["createdAt"] = ISO8601DateFormatter().string(from: createdAt) }
        if let modifiedAt = item.modifiedAt { value["modifiedAt"] = ISO8601DateFormatter().string(from: modifiedAt) }
        return value
    }

    private struct Scope {
        let accessGroup: String
        let keychainGroupID: Int
    }

    private static func scope(for container: LCContainer) throws -> Scope {
        guard let team = LCSharedUtils.teamIdentifier(), !team.isEmpty else {
            throw LCGuestKeychainError.scope("无法确定宿主签名团队，不能定位 Guest Keychain 组。")
        }
        let raw = container.keychainGroupId
        let groupID = raw < 0 ? 0 : raw
        guard (0..<SharedModel.keychainAccessGroupCount).contains(groupID) else {
            throw LCGuestKeychainError.scope("容器的 Keychain 组编号无效。")
        }
        let group = team + ".com.kdt.livecontainer.shared" + (groupID == 0 ? "" : ".\(groupID)")
        return Scope(accessGroup: group, keychainGroupID: groupID)
    }

    private static func list(
        _ itemClass: LCGuestKeychainClass,
        scope: Scope,
        container: LCContainer,
        authenticationContext: LAContext?
    ) throws -> [LCGuestKeychainItem] {
        var query: [String: Any] = [
            kSecClass as String: itemClass.securityClass,
            kSecAttrAccessGroup as String: scope.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        apply(authenticationContext, to: &query)
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecParam {
            query.removeValue(forKey: kSecReturnPersistentRef as String)
            result = nil
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecParam {
            // Some item classes reject access-group filters on older systems.
            // Retry without that filter, then keep only entries whose returned
            // access group matches this container.
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            result = nil
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw error("读取\(itemClass.rawValue)失败", status: status) }

        let dictionaries: [[String: Any]]
        if let values = result as? [[String: Any]] {
            dictionaries = values
        } else if let value = result as? [String: Any] {
            dictionaries = [value]
        } else {
            return []
        }

        return dictionaries.compactMap { attributes in
            // Older containers may not expose the internal container alias.
            // When it exists, require it to match so shared legacy groups stay strict.
            let alias = stringValue(attributes["alis"])
            if !alias.isEmpty, alias != container.folderName {
                return nil
            }
            if stringValue(attributes[kSecAttrAccessGroup as String]) != scope.accessGroup {
                return nil
            }
            let persistent = attributes[kSecValuePersistentRef as String] as? Data
            let service = serviceDescription(attributes, itemClass: itemClass)
            let account = attributes[kSecAttrAccount as String] as? String ?? ""
            let label = stringValue(attributes[kSecAttrLabel as String])
            let created = attributes[kSecAttrCreationDate as String] as? Date
            let modified = attributes[kSecAttrModificationDate as String] as? Date
            let seed = persistent?.base64EncodedString()
                ?? [itemClass.rawValue, service, account, label, String(created?.timeIntervalSince1970 ?? 0)].joined(separator: "\u{1f}")
            let digest = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
            return LCGuestKeychainItem(
                id: digest,
                itemClass: itemClass,
                source: .host,
                service: service,
                account: account,
                label: label,
                createdAt: created,
                modifiedAt: modified,
                persistentReference: persistent,
                attributes: attributes
            )
        }
    }

    private static func serviceDescription(_ attributes: [String: Any], itemClass: LCGuestKeychainClass) -> String {
        if let service = attributes[kSecAttrService as String] as? String, !service.isEmpty {
            return service
        }
        if itemClass == .internetPassword {
            let server = attributes[kSecAttrServer as String] as? String ?? ""
            let path = attributes[kSecAttrPath as String] as? String ?? ""
            let port = attributes[kSecAttrPort as String].map { String(describing: $0) } ?? ""
            return server + (port.isEmpty ? "" : ":\(port)") + path
        }
        if let label = attributes[kSecAttrLabel as String] as? String, !label.isEmpty { return label }
        if let subject = attributes[kSecAttrSubject as String] as? String, !subject.isEmpty { return subject }
        return itemClass.rawValue
    }

    private static func copyData(_ item: LCGuestKeychainItem, scope: Scope, authenticationContext: LAContext?) throws -> Data {
        var query = baseQuery(item, scope: scope, authenticationContext: authenticationContext)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if (status == errSecParam || status == errSecItemNotFound), item.persistentReference != nil {
            query.removeValue(forKey: kSecMatchItemList as String)
            query.merge(item.matchingAttributes) { _, new in new }
            result = nil
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw error("读取敏感值失败", status: status)
        }
        return data
    }

    private static func copyReference(_ item: LCGuestKeychainItem, scope: Scope, authenticationContext: LAContext?) throws -> CFTypeRef {
        var query = baseQuery(item, scope: scope, authenticationContext: authenticationContext)
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if (status == errSecParam || status == errSecItemNotFound), item.persistentReference != nil {
            query.removeValue(forKey: kSecMatchItemList as String)
            query.merge(item.matchingAttributes) { _, new in new }
            result = nil
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess, let result else {
            throw error("读取受保护对象失败", status: status)
        }
        return result
    }

    private static func baseQuery(
        _ item: LCGuestKeychainItem,
        scope: Scope,
        authenticationContext: LAContext?
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: item.itemClass.securityClass,
            kSecAttrAccessGroup as String: scope.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let reference = item.persistentReference {
            query[kSecMatchItemList as String] = [reference]
        } else {
            query.merge(item.matchingAttributes) { _, new in new }
        }
        apply(authenticationContext, to: &query)
        return query
    }

    private static func apply(_ context: LAContext?, to query: inout [String: Any]) {
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
    }

    private static func render(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") {
            return text.isEmpty ? "（空值）" : text
        }
        return "Base64：\n" + data.base64EncodedString()
    }

    private static func stringValue(_ value: Any?) -> String {
        switch value {
        case let value as String: return value
        case let value as Data: return String(data: value, encoding: .utf8) ?? value.base64EncodedString()
        default: return value.map { String(describing: $0) } ?? ""
        }
    }

    private static func error(_ context: String, status: OSStatus) -> Error {
        if status == errSecMissingEntitlement {
            return LCGuestKeychainError.missingEntitlement(
                "\(context)：当前 iAppVM 签名未包含该 Guest Keychain 组。请使用同时包含共享组和 128 个 Guest 组的开发签名。"
            )
        }
        if status == errSecInteractionNotAllowed || status == errSecNotAvailable {
            return LCGuestKeychainError.read("\(context)：设备当前锁定或 Keychain 暂不可访问。请解锁 iPhone 后刷新。")
        }
        if status == errSecAuthFailed {
            return LCGuestKeychainError.read("\(context)：系统拒绝访问，请解锁 iPhone 后重试。")
        }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return LCGuestKeychainError.read("\(context)：\(message)")
    }
}

enum LCGuestKeychainError: LocalizedError {
    case scope(String)
    case read(String)
    case auth(String)
    case missingEntitlement(String)

    var isMissingEntitlement: Bool {
        if case .missingEntitlement = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .scope(let text), .read(let text), .auth(let text), .missingEntitlement(let text):
            return text
        }
    }
}
