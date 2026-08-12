import Foundation

/// End-to-end regression test for the exact embedded mihomo executable and a cached provider
/// document. Invoke it with the core executable path and a provider YAML path.
@main
struct LiveMihomoIntegrationTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("usage: LiveMihomoIntegrationTests <mihomo-path> <provider-yaml>\\n", stderr)
            exit(64)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let provider = URL(fileURLWithPath: CommandLine.arguments[2])
        let nodes = SubscriptionService().parse(data: try Data(contentsOf: provider), sourceID: "live")
        guard let selected = nodes.first(where: \.supported)?.name else {
            throw TunnelError.connect("测试订阅中没有可用节点")
        }

        let core = MihomoCore(executableOverride: executable)
        try core.start(providerFile: provider, selectedNode: selected)
        defer { core.stopAndWait() }

        let latencies = try await core.groupLatencies()
        guard let (node, latency) = latencies.first(where: { $0.value > 0 }) else {
            throw TunnelError.connect("核心组测速没有返回可用节点")
        }
        try await core.select(node: node)
        let singleLatency = try await core.latency(node: node)
        print("PASS: 核心已加载 \(nodes.filter(\.supported).count) 个可用节点，组测速 \(latencies.count) 个，单节点 \(node) 为 \(singleLatency) ms（组测速 \(latency) ms）")
    }
}
