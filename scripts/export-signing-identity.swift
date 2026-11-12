// Export exactly one selected signing identity; never export the whole keychain.
import Foundation
import Security
import CryptoKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard CommandLine.arguments.count == 4 else { fail("Usage: export-signing-identity SHA1 HOST_BUNDLE_ID OUTPUT_PLIST") }
let fingerprint = CommandLine.arguments[1].uppercased()
guard fingerprint.range(of: "^[0-9A-F]{40}$", options: .regularExpression) != nil else { fail("Invalid certificate fingerprint") }
let destination = URL(fileURLWithPath: CommandLine.arguments[3])
guard !FileManager.default.fileExists(atPath: destination.path) else { fail("Refusing to overwrite an existing file") }
var items: CFTypeRef?
let status = SecItemCopyMatching([kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true] as CFDictionary, &items)
guard status == errSecSuccess, let identities = items as? [SecIdentity] else { fail("Cannot read signing identities") }
let matches = identities.filter { identity in
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return false }
    let der = SecCertificateCopyData(certificate) as Data
    return Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined() == fingerprint
}
guard let identity = matches.first else { fail("Selected signing identity is unavailable") }
var random = [UInt8](repeating: 0, count: 32)
guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { fail("Cannot generate export password") }
let password = random.map { String(format: "%02x", $0) }.joined() as CFString
var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
parameters.passphrase = Unmanaged.passUnretained(password)
var exported: CFData?
let exportStatus = SecItemExport(identity, .formatPKCS12, [], &parameters, &exported)
guard exportStatus == errSecSuccess, let exported else { fail("Selected private key export failed (OSStatus \(exportStatus)); macOS may require Keychain approval") }
let config: [String: Any] = ["id": UUID().uuidString, "host": CommandLine.arguments[2], "certificate": exported as Data, "password": password as String]
do {
    let data = try PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
    // POSIX permissions are applied at creation, before any credential bytes are written.
    guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { fail("Cannot create private configuration file") }
    let handle = try FileHandle(forWritingTo: destination)
    try handle.write(contentsOf: data)
    try handle.close()
    print("Selected identity exported to a private one-time provisioning file.")
} catch { try? FileManager.default.removeItem(at: destination); fail("Cannot save provisioning file") }
