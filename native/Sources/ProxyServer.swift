import Foundation
import Darwin

final class ProxyServer: @unchecked Sendable {
    struct Context: Sendable {
        let mode: ProxyMode
        let rules: [RoutingRule]
        let node: ProxyNode?
        let coreSocksPort: Int?
    }
    var context: @Sendable () -> Context = { .init(mode: .rule, rules: RoutingRule.builtIns, node: nil, coreSocksPort: nil) }
    var onOpen: @Sendable (UUID, String, Int, RouteDecision, String?) -> Void = { _,_,_,_,_ in }
    var onTraffic: @Sendable (UUID, Int64, Int64) -> Void = { _,_,_ in }
    var onClose: @Sendable (UUID, String?) -> Void = { _,_ in }
    private let router: RoutingEngine
    private let queue = DispatchQueue(label: "app.zhilian.proxy.accept", qos: .utility)
    private var listener: Int32 = -1
    private var running = false

    init(router: RoutingEngine) { self.router = router }

    func start(port: Int) throws {
        guard !running else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw TunnelError.connect("无法创建监听端口") }
        var reuse: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: in_port_t(port).bigEndian,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0,0,0,0,0,0,0,0))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 128) == 0 else { Darwin.close(fd); throw TunnelError.connect("本地端口 \(port) 被占用") }
        listener = fd; running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() { running = false; if listener >= 0 { Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener); listener = -1 } }

    private func acceptLoop() {
        while running {
            let client = accept(listener, nil, nil)
            if client < 0 {
                // `accept` is unblocked when stop() closes the listener.  A small
                // backoff also protects against a transient descriptor failure
                // becoming a busy loop that consumes a full CPU core.
                if !running { break }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.handle(SocketFD(fd: client)) }
        }
    }

    private func handle(_ client: SocketFD) {
        let id = UUID(); var tunnel: Tunnel?
        do {
            var header = Data()
            while !header.contains(Data("\r\n\r\n".utf8)) && header.count < 65536 {
                let chunk = try client.read(max: 4096); if chunk.isEmpty { throw TunnelError.closed }; header.append(chunk)
            }
            guard let headerEnd = header.range(of: Data("\r\n\r\n".utf8)), let text = String(data: header[..<headerEnd.upperBound], encoding: .utf8) else { throw TunnelError.protocolError("HTTP 请求无效") }
            let lines = text.components(separatedBy: "\r\n"); let first = lines[0].split(separator: " ")
            guard first.count >= 2 else { throw TunnelError.protocolError("请求行无效") }
            let method = String(first[0]).uppercased(), target = String(first[1])
            let hostPort: (String, Int)
            if method == "CONNECT" { hostPort = Self.parseHostPort(target, defaultPort: 443) }
            else if let url = URL(string: target), let host = url.host { hostPort = (host, url.port ?? (url.scheme == "https" ? 443 : 80)) }
            else { let hostLine = lines.first { $0.lowercased().hasPrefix("host:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? ""; hostPort = Self.parseHostPort(hostLine, defaultPort: 80) }
            guard !hostPort.0.isEmpty else { throw TunnelError.protocolError("缺少目标服务器") }
            let current = context(), decision = router.decide(host: hostPort.0, port: hostPort.1, mode: current.mode, rules: current.rules)
            if decision.action == .reject { throw TunnelError.protocolError("已被规则拒绝") }
            if decision.action == .proxy, let corePort = current.coreSocksPort { tunnel = try Socks5Tunnel(proxyPort: corePort, destinationHost: hostPort.0, destinationPort: hostPort.1) }
            else if decision.action == .proxy, let node = current.node, node.type == "ss" { tunnel = try ShadowsocksTunnel(node: node, destinationHost: hostPort.0, destinationPort: hostPort.1) }
            else { tunnel = try SocketFD.connect(host: hostPort.0, port: hostPort.1) }
            onOpen(id, hostPort.0, hostPort.1, decision, decision.action == .proxy ? current.node?.name : nil)
            if method == "CONNECT" { try client.write(Data("HTTP/1.1 200 Connection Established\r\nProxy-Agent: Zhilian/0.3\r\n\r\n".utf8)) }
            else {
                var path = target
                if let url = URL(string: target), url.scheme != nil { path = url.path.isEmpty ? "/" : url.path; if let query = url.query { path += "?" + query } }
                let cleanLines = lines.dropFirst().filter { !$0.lowercased().hasPrefix("proxy-") }
                var outgoing = Data("\(method) \(path) HTTP/1.1\r\n".utf8); outgoing.append(Data(cleanLines.joined(separator: "\r\n").utf8)); outgoing.append(Data("\r\n".utf8)); outgoing.append(header[headerEnd.upperBound...]); try tunnel!.write(outgoing)
            }
            relay(client: client, tunnel: tunnel!, id: id)
        } catch {
            // Before a CONNECT tunnel is established, return a proper HTTP proxy error. This
            // makes node/server failures observable to clients instead of looking like a crash.
            let message = error.localizedDescription
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n智连代理连接失败：\(message)"
            try? client.write(Data(response.utf8))
            client.close(); tunnel?.close(); onClose(id, message)
        }
    }

    private func relay(client: SocketFD, tunnel: Tunnel, id: UUID) {
        let group = DispatchGroup(); let finished = NSLock(); var closed = false
        func finish(_ error: String?) { finished.lock(); defer { finished.unlock() }; if !closed { closed = true; client.close(); tunnel.close(); onClose(id, error) } }
        group.enter(); DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave(); finish(nil) }
            do { while true { let data = try client.read(); if data.isEmpty { break }; try tunnel.write(data); self.onTraffic(id, Int64(data.count), 0) } } catch { finish(error.localizedDescription) }
        }
        group.enter(); DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave(); finish(nil) }
            do { while true { let data = try tunnel.read(); if data.isEmpty { break }; try client.write(data); self.onTraffic(id, 0, Int64(data.count)) } } catch { finish(error.localizedDescription) }
        }
    }

    private static func parseHostPort(_ value: String, defaultPort: Int) -> (String, Int) {
        if value.hasPrefix("["), let end = value.firstIndex(of: "]") { let host = String(value[value.index(after: value.startIndex)..<end]); let rest = value[value.index(after: end)...]; return (host, Int(rest.dropFirst()) ?? defaultPort) }
        if let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) { return (String(value[..<colon]), port) }
        return (value, defaultPort)
    }
}
