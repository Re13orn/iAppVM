import Foundation
import Combine
import Network

/// Host-side, user-initiated check. A completed CONNECT is not a TLS or guest-coverage claim.
@MainActor final class LCProxyDiagnostic: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var result = "尚未测试"
    private var connection: NWConnection?
    private var serial = UUID()
    private var timer: Task<Void, Never>?
    private var buffer = Data()
    private var stage = 0
    private var kind = "http"

    func cancel() {
        serial = UUID(); connection?.cancel(); connection = nil; timer?.cancel(); timer = nil
        if running { result = "测试已取消" }; running = false
    }
    func test(kind: String, host: String, port: Int) {
        cancel()
        guard ["http", "socks5"].contains(kind), !host.isEmpty, (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            result = "先填写有效的代理类型、服务器与端口。"; return
        }
        self.kind = kind; buffer = Data(); stage = 0; running = true; result = "正在连接代理…"
        let id = UUID(); serial = id
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.serial == id, self.running else { return }
                switch state {
                case .ready:
                    self.result = "TCP 已连接，正在验证代理握手…"
                    if kind == "http" { self.send(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8), id: id) }
                    else { self.send(Data([5,1,0]), id: id) }
                case .waiting(let error), .failed(let error): self.finish("代理连接失败：" + error.localizedDescription, id: id)
                default: break
                }
            }
        }
        connection.start(queue: DispatchQueue(label: "dev.iosvm.proxy-check"))
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            self?.finish("测试超时。请检查地址、同网状态、本地网络权限，以及代理是否等待手动放行。", id: id)
        }
    }
    private func send(_ data: Data, id: UUID) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, self.serial == id else { return }
                if let error { self.finish("发送失败：" + error.localizedDescription, id: id) }
                else { self.receive(id: id) }
            }
        })
    }
    private func receive(id: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.serial == id, self.running else { return }
                if let data { self.buffer.append(data) }
                if self.buffer.count > 16384 { self.finish("代理响应头过大。", id: id); return }
                if self.consume(id: id) { return }
                if let error { self.finish("代理响应失败：" + error.localizedDescription, id: id) }
                else if complete { self.finish("代理提前关闭连接。", id: id) }
                else { self.receive(id: id) }
            }
        }
    }
    private func consume(id: UUID) -> Bool {
        if kind == "http" {
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else { return false }
            let line = String(decoding: buffer.prefix(256), as: UTF8.self).components(separatedBy: "\r\n")[0]
            let words = line.split(separator: " ")
            let code = words.count >= 2 ? Int(words[1]) : nil
            if let code, (200...299).contains(code), words[0] == "HTTP/1.1" || words[0] == "HTTP/1.0" { succeeded(id: id) }
            else if code == 407 { finish("代理要求认证；当前仅支持无认证代理。", id: id) }
            else { finish("HTTP CONNECT 未通过：" + line, id: id) }
            return true
        }
        if stage == 0 {
            guard buffer.count >= 2 else { return false }
            guard buffer[0] == 5, buffer[1] == 0 else { finish("SOCKS5 不接受无认证连接。", id: id); return true }
            stage = 1; buffer = Data()
            var request = Data([5,1,0,3,11]); request.append(Data("example.com".utf8)); request.append(contentsOf: [1,187])
            send(request, id: id); return true
        }
        guard buffer.count >= 4 else { return false }
        guard buffer[0] == 5, buffer[1] == 0, buffer[2] == 0 else { finish("SOCKS5 拒绝目标连接，返回码 \(buffer[1])。", id: id); return true }
        let length: Int
        switch buffer[3] {
        case 1: length = 10
        case 4: length = 22
        case 3: guard buffer.count >= 5 else { return false }; length = 7 + Int(buffer[4])
        default: finish("SOCKS5 响应地址格式无效。", id: id); return true
        }
        guard buffer.count >= length else { return false }
        succeeded(id: id); return true
    }
    private func succeeded(id: UUID) { finish("代理握手通过（example.com:443）。尚未验证 TLS 信任，也不代表目标 App 的所有流量都经过代理。", id: id) }
    private func finish(_ text: String, id: UUID) {
        guard serial == id else { return }
        result = text; running = false; timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
    }
}
