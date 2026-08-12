import Foundation

/// Fetches the configured subscription without printing its URL or credentials.
@main
struct LiveSubscriptionRefreshTests {
    static func main() async throws {
        guard let profile = ConfigStore().load().subscriptions.first else {
            throw SubscriptionError.empty
        }
        let result = try await SubscriptionService().fetchResult(url: profile.url, sourceID: "live-refresh")
        let supported = result.nodes.filter(\.supported).count
        guard supported > 0 else { throw SubscriptionError.unsupported }
        guard !result.document.isEmpty else { throw SubscriptionError.empty }
        print("PASS: 当前订阅在线刷新成功，共 \(result.nodes.count) 个条目，\(supported) 个可用节点；地址与令牌未输出")
    }
}
