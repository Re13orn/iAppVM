import Foundation
import Security
import CryptoKit

@main struct TLSAnalysisTests {
    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundle = fixture.appendingPathComponent("StaticFixture.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let der = try Data(contentsOf: fixture.appendingPathComponent("server.der"))
        let pem = try Data(contentsOf: fixture.appendingPathComponent("server.pem"))
        guard let certificate = LCTLSCertificate(der: der) else { fatalError("valid X.509 was not parsed") }
        precondition(certificate.subject == "localhost")
        precondition(certificate.issuer == "iAppVM TLS Test CA")
        precondition(certificate.notBefore != nil && certificate.notAfter != nil)
        precondition(certificate.sha256 == LCTLSCertificate.digest(der))
        let expectedSPKI = try String(contentsOf: fixture.appendingPathComponent("spki.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(certificate.spkiSHA256 == expectedSPKI)
        precondition(LCTLSAnalysis.certificates(pem + pem).count == 2)
        precondition(LCTLSCertificate(der: Data(der.dropLast())) == nil)
        precondition(LCTLSCertificate(der: Data([0x30, 0x84, 0xff, 0xff, 0xff, 0xff])) == nil)
        try der.write(to: bundle.appendingPathComponent("without-extension"))
        try pem.write(to: bundle.appendingPathComponent("roots.pem"))
        try Data("not a certificate".utf8).write(to: bundle.appendingPathComponent("invalid.cer"))
        try Data("not inspected".utf8).write(to: bundle.appendingPathComponent("candidate.p12"))
        try der.write(to: bundle.appendingPathComponent("embedded.mobileprovision"))
        let signing = bundle.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: signing, withIntermediateDirectories: true)
        try der.write(to: signing.appendingPathComponent("signing.cer"))
        let link = bundle.appendingPathComponent("external.cer")
        if !FileManager.default.fileExists(atPath: link.path) { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.appendingPathComponent("client.der")) }
        let config: [String: Any] = ["NSAppTransportSecurity": ["NSPinnedDomains": ["example.test": ["NSPinnedLeafIdentities": [["SPKI-SHA256-BASE64": certificate.spkiSHA256!]]]]]]
        try PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        try JSONSerialization.data(withJSONObject: ["nested": config]).write(to: bundle.appendingPathComponent("candidate.json"))
        let result = try LCTLSAnalysis.scan(bundle: bundle)
        precondition(result.findings.filter { $0.kind == "certificate" }.count == 2)
        precondition(result.findings.filter { $0.kind == "ats-pinning" }.count == 1)
        precondition(result.findings.filter { $0.kind == "pin-config-candidate" }.count == 1)
        precondition(result.findings.contains { $0.kind == "identity-candidate" })
        precondition(!result.findings.contains { $0.path.contains("CodeSignature") || $0.path.contains("mobileprovision") || $0.path == "external.cer" })
        do { _ = try LCTLSAnalysis.scan(bundle: bundle, cancelled: { true }); fatalError("cancellation ignored") }
        catch is CancellationError { }
        print("PASS static TLS: DER/PEM/content sniff, SPKI vs OpenSSL, validity, config evidence, malformed input, signing exclusions, symlink and cancellation")
    }
}
