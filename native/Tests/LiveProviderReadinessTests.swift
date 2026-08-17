import Foundation

/// Verifies that start() does not return while the selector is still empty.
@main
struct LiveProviderReadinessTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("usage: LiveProviderReadinessTests <mihomo-path> <provider-yaml>\n", stderr)
            exit(64)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let provider = URL(fileURLWithPath: CommandLine.arguments[2])
        let nodes = SubscriptionService().parse(data: try Data(contentsOf: provider), sourceID: "readiness")
        guard let selected = nodes.first(where: \.isSelectableProxy)?.name else {
            throw TunnelError.connect("测试订阅没有可选节点")
        }
        let core = MihomoCore(executableOverride: executable)
        let startedAt = Date()
        try core.start(providerFile: provider, selectedNode: selected)
        defer { core.stopAndWait() }
        try await core.validateProviderLoaded()
        let elapsed = Date().timeIntervalSince(startedAt)
        print(String(format: "PASS: 核心在 %.2f 秒内启动，并在 start() 返回前加载了节点组", elapsed))
    }
}
