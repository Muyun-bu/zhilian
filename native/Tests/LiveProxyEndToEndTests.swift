import Foundation

/// Runs the user-facing data path: local HTTP proxy -> local mihomo SOCKS -> selected node -> web.
/// Invoke it with the bundled core executable, a cached provider YAML and china-ip-ranges.txt.
@main
struct LiveProxyEndToEndTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            fputs("usage: LiveProxyEndToEndTests <mihomo-path> <provider-yaml> <china-ip-ranges>\\n", stderr)
            exit(64)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let provider = URL(fileURLWithPath: CommandLine.arguments[2])
        let nodes = SubscriptionService().parse(data: try Data(contentsOf: provider), sourceID: "live")
        guard let fallback = nodes.first(where: \.supported)?.name else {
            throw TunnelError.connect("测试订阅中没有可用节点")
        }

        let core = MihomoCore(executableOverride: executable)
        try core.start(providerFile: provider, selectedNode: fallback)
        defer { core.stopAndWait() }
        let results = try await core.groupLatencies()
        let candidates = results.sorted { $0.value < $1.value }.map(\.key)
        guard !candidates.isEmpty else { throw TunnelError.connect("没有通过核心测速的节点") }

        var firstFailure: Error?
        for selected in candidates {
            do {
                try await core.select(node: selected)
                try connectThrough(proxyPort: core.socksPort, host: "example.com", port: 443)
                print("PASS: 核心 SOCKS 已通过节点 \(selected) 建立 example.com 的 HTTPS 隧道")
                return
            } catch {
                firstFailure = error
            }
        }
        throw firstFailure ?? TunnelError.connect("所有已测速节点均无法通过 SOCKS 建立 HTTPS 隧道")
    }

    private static func connectThrough(proxyPort: Int, host: String, port destinationPort: Int) throws {
        let proxy = ProxyServer(router: RoutingEngine(database: IPDatabase(resourceURL: URL(fileURLWithPath: CommandLine.arguments[3]))))
        proxy.context = { .init(mode: .global, rules: RoutingRule.builtIns, node: nil, coreSocksPort: proxyPort) }
        let listenerPort = try start(proxy: proxy)
        defer { proxy.stop() }

        let client = try SocketFD.connect(host: "127.0.0.1", port: listenerPort, timeout: 15)
        defer { client.close() }
        try client.write(Data("CONNECT \(host):\(destinationPort) HTTP/1.1\r\nHost: \(host):\(destinationPort)\r\nProxy-Connection: keep-alive\r\n\r\n".utf8))
        let response = try client.read(max: 4096)
        let text = String(data: response, encoding: .utf8) ?? ""
        guard text.hasPrefix("HTTP/") else {
            throw TunnelError.protocolError("本地代理没有返回 HTTP 响应")
        }
        guard text.contains(" 200 ") else {
            throw TunnelError.protocolError("本地代理没有建立 HTTPS 隧道：\(text)")
        }
    }

    private static func start(proxy: ProxyServer) throws -> Int {
        let first = 29_000 + Int(ProcessInfo.processInfo.processIdentifier % 500)
        for port in first..<(first + 20) {
            do { try proxy.start(port: port); return port } catch { continue }
        }
        throw TunnelError.connect("没有可用于端到端测试的本地端口")
    }
}
