import Foundation

/// Regression test for the low-CPU production route:
/// macOS HTTP proxy -> mihomo mixed-port -> selected node -> web.
@main
struct LiveMixedPortEndToEndTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("usage: LiveMixedPortEndToEndTests <mihomo-path> <provider-yaml>\n", stderr)
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
        let candidates = try await core.groupLatencies().sorted { $0.value < $1.value }.map(\.key)
        guard !candidates.isEmpty else { throw TunnelError.connect("没有通过核心测速的节点") }

        var firstFailure: Error?
        for selected in candidates {
            do {
                try await core.select(node: selected)
                let proxyClient = try connectThroughHTTPProxy(port: core.mixedPort, host: "example.com", destinationPort: 443)
                let directClient = try connectThroughHTTPProxy(port: core.mixedPort, host: "114.114.114.114", destinationPort: 53)
                try? await Task.sleep(nanoseconds: 200_000_000)
                let snapshot = try await core.connectionSnapshot()
                guard snapshot.connections.contains(where: { $0.host == "example.com" && $0.action == .proxy }) else {
                    proxyClient.close(); directClient.close()
                    throw TunnelError.protocolError("核心连接快照未记录代理连接")
                }
                guard snapshot.connections.contains(where: { $0.host == "114.114.114.114" && $0.action == .direct }) else {
                    proxyClient.close(); directClient.close()
                    throw TunnelError.protocolError("中国服务器 IP 未按本地 CIDR 规则直连")
                }
                proxyClient.close(); directClient.close()
                print("PASS: 境外 example.com 已通过节点 \(selected) 代理，中国 IP 114.114.114.114 已直连，连接快照真实可读")
                return
            } catch { firstFailure = error }
        }
        throw firstFailure ?? TunnelError.connect("所有已测速节点均无法通过 mixed-port 建立 HTTPS 隧道")
    }

    private static func connectThroughHTTPProxy(port: Int, host: String, destinationPort: Int) throws -> SocketFD {
        let client = try SocketFD.connect(host: "127.0.0.1", port: port, timeout: 15)
        try client.write(Data("CONNECT \(host):\(destinationPort) HTTP/1.1\r\nHost: \(host):\(destinationPort)\r\nProxy-Connection: keep-alive\r\n\r\n".utf8))
        let response = try client.read(max: 4096)
        let text = String(data: response, encoding: .utf8) ?? ""
        guard text.hasPrefix("HTTP/"), text.contains(" 200 ") else {
            client.close()
            throw TunnelError.protocolError("mixed-port 没有建立 HTTPS 隧道：\(text)")
        }
        return client
    }
}
