// Access only a selected matching local identity. Private exports travel over an anonymous pipe.
import Foundation
import Security
import CryptoKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
func identities() -> [SecIdentity] {
    var result: CFTypeRef?
    let status=SecItemCopyMatching([kSecClass:kSecClassIdentity,kSecMatchLimit:kSecMatchLimitAll,kSecReturnRef:true] as CFDictionary,&result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { fail("无法读取本机签名身份（OSStatus \(status)），请解锁登录钥匙串。") }
    return result as? [SecIdentity] ?? []
}
func certificate(_ identity: SecIdentity) -> SecCertificate? {
    var value: SecCertificate?
    guard SecIdentityCopyCertificate(identity,&value) == errSecSuccess else { return nil }
    return value
}
func fingerprint(_ cert: SecCertificate) -> String {
    Insecure.SHA1.hash(data:SecCertificateCopyData(cert) as Data).map {String(format:"%02X",$0)}.joined()
}
guard CommandLine.arguments.count >= 2 else { fail("缺少操作") }
switch CommandLine.arguments[1] {
case "list":
    let items:[[String:Any]]=identities().compactMap { identity in
        guard let cert=certificate(identity) else { return nil }
        var key:SecKey?
        guard SecIdentityCopyPrivateKey(identity,&key) == errSecSuccess, let key,
              let attrs=SecKeyCopyAttributes(key) as? [String:Any],
              attrs[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeRSA as String else { return nil }
        return ["fingerprint":fingerprint(cert),"certificate":(SecCertificateCopyData(cert) as Data).base64EncodedString(),
                "name":SecCertificateCopySubjectSummary(cert) as String? ?? "Apple Development"]
    }
    let bytes=try JSONSerialization.data(withJSONObject:items)
    FileHandle.standardOutput.write(bytes)
case "export":
    guard CommandLine.arguments.count == 3,
          CommandLine.arguments[2].range(of:"^[0-9A-F]{40}$",options:.regularExpression) != nil else { fail("证书指纹无效") }
    guard let selected=identities().first(where:{ identity in
        guard let cert=certificate(identity) else { return false };return fingerprint(cert)==CommandLine.arguments[2]
    }) else { fail("选中的签名身份已不可用") }
    var random=[UInt8](repeating:0,count:32)
    guard SecRandomCopyBytes(kSecRandomDefault,random.count,&random)==errSecSuccess else { fail("无法生成传输密码") }
    let password=random.map { String(format:"%02x",$0) }.joined() as CFString
    var params=SecItemImportExportKeyParameters();params.version=UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    params.passphrase=Unmanaged.passUnretained(password)
    var archive:CFData?
    let status=SecItemExport(selected,.formatPKCS12,[],&params,&archive)
    guard status==errSecSuccess,let archive else { fail("读取选中私钥失败（OSStatus \(status)）；如有系统提示，请在本机允许此次钥匙串访问。") }
    let payload:[String:Any]=["certificate":archive as Data,"password":password as String]
    let bytes=try PropertyListSerialization.data(fromPropertyList:payload,format:.binary,options:0)
    FileHandle.standardOutput.write(bytes)
default: fail("不支持的操作")
}
