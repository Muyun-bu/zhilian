import Foundation
import Darwin

private final class RelayCloser: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private let client: SocketFD
    private let tunnel: Tunnel
    private let completion: @Sendable (String?) -> Void

    init(client: SocketFD, tunnel: Tunnel, completion: @escaping @Sendable (String?) -> Void) {
        self.client = client
        self.tunnel = tunnel
        self.completion = completion
    }

    func finish(_ error: String?) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        client.close()
        tunnel.close()
        completion(error)
    }
}

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
    private let stateLock = NSLock()
    private var listener: Int32 = -1
    private var generation: UInt64 = 0

    init(router: RoutingEngine) { self.router = router }

    func start(port: Int) throws {
        guard (1...65_535).contains(port) else { throw TunnelError.connect("本地代理端口无效") }
        stateLock.lock()
        let alreadyRunning = listener >= 0
        stateLock.unlock()
        guard !alreadyRunning else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw TunnelError.connect("无法创建监听端口") }
        var reuse: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: in_port_t(port).bigEndian,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0,0,0,0,0,0,0,0))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 128) == 0 else { Darwin.close(fd); throw TunnelError.connect("本地端口 \(port) 被占用") }
        stateLock.lock()
        guard listener < 0 else { stateLock.unlock(); Darwin.close(fd); return }
        listener = fd
        generation &+= 1
        let activeGeneration = generation
        stateLock.unlock()
        queue.async { [weak self] in self?.acceptLoop(fd: fd, generation: activeGeneration) }
    }

    func stop() {
        stateLock.lock()
        let fd = listener
        listener = -1
        generation &+= 1
        stateLock.unlock()
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
    }

    private func acceptLoop(fd: Int32, generation: UInt64) {
        while isActive(generation) {
            let client = accept(fd, nil, nil)
            if client < 0 {
                // `accept` is unblocked when stop() closes the listener.  A small
                // backoff also protects against a transient descriptor failure
                // becoming a busy loop that consumes a full CPU core.
                if !isActive(generation) { break }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            guard isActive(generation) else { Darwin.close(client); break }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.handle(SocketFD(fd: client)) }
        }
    }

    private func isActive(_ expectedGeneration: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return listener >= 0 && generation == expectedGeneration
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
            guard let activeTunnel = tunnel else { throw TunnelError.connect("无法建立转发通道") }
            onOpen(id, hostPort.0, hostPort.1, decision, decision.action == .proxy ? current.node?.name : nil)
            if method == "CONNECT" { try client.write(Data("HTTP/1.1 200 Connection Established\r\nProxy-Agent: Zhilian/0.3\r\n\r\n".utf8)) }
            else {
                var path = target
                if let url = URL(string: target), url.scheme != nil { path = url.path.isEmpty ? "/" : url.path; if let query = url.query { path += "?" + query } }
                let cleanLines = lines.dropFirst().filter { !$0.lowercased().hasPrefix("proxy-") }
                var outgoing = Data("\(method) \(path) HTTP/1.1\r\n".utf8); outgoing.append(Data(cleanLines.joined(separator: "\r\n").utf8)); outgoing.append(Data("\r\n".utf8)); outgoing.append(header[headerEnd.upperBound...]); try activeTunnel.write(outgoing)
            }
            relay(client: client, tunnel: activeTunnel, id: id)
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
        let group = DispatchGroup()
        let closer = RelayCloser(client: client, tunnel: tunnel) { [onClose] error in onClose(id, error) }
        group.enter(); DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave(); closer.finish(nil) }
            do { while true { let data = try client.read(); if data.isEmpty { break }; try tunnel.write(data); self.onTraffic(id, Int64(data.count), 0) } } catch { closer.finish(error.localizedDescription) }
        }
        group.enter(); DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave(); closer.finish(nil) }
            do { while true { let data = try tunnel.read(); if data.isEmpty { break }; try client.write(data); self.onTraffic(id, 0, Int64(data.count)) } } catch { closer.finish(error.localizedDescription) }
        }
    }

    private static func parseHostPort(_ value: String, defaultPort: Int) -> (String, Int) {
        if value.hasPrefix("["), let end = value.firstIndex(of: "]") { let host = String(value[value.index(after: value.startIndex)..<end]); let rest = value[value.index(after: end)...]; let port = Int(rest.dropFirst()).flatMap { (1...65_535).contains($0) ? $0 : nil }; return (host, port ?? defaultPort) }
        if let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]), (1...65_535).contains(port) { return (String(value[..<colon]), port) }
        return (value, defaultPort)
    }
}
