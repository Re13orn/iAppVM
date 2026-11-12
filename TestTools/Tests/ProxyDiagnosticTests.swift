import Foundation
@main struct ProxyDiagnosticTests {
    @MainActor static func main() async throws {
        let diagnostic = LCProxyDiagnostic()
        for (kind,port,expected) in [("http",19191,"代理握手通过"),("socks5",19192,"代理握手通过"),("http",19193,"代理要求认证"),("http",19195,"代理连接失败"),("http",19194,"测试超时")] {
            diagnostic.test(kind: kind, host: "127.0.0.1", port: port)
            while diagnostic.running { try await Task.sleep(nanoseconds: 50_000_000) }
            guard diagnostic.result.hasPrefix(expected) else { fatalError("\(kind):\(port) → \(diagnostic.result)") }
            print("PASS diagnostic \(kind):\(port) → \(expected)")
        }
        diagnostic.test(kind: "http", host: "127.0.0.1", port: 19194)
        diagnostic.cancel()
        diagnostic.test(kind: "socks5", host: "127.0.0.1", port: 19192)
        while diagnostic.running { try await Task.sleep(nanoseconds: 50_000_000) }
        guard diagnostic.result.hasPrefix("代理握手通过") else { fatalError("stale callback replaced current result") }
        print("PASS cancel/restart ignores stale connection callbacks")
    }
}
