import Foundation

enum ProxyMode: String, Codable, CaseIterable, Identifiable {
    case rule, global, direct
    var id: String { rawValue }
    var title: String {
        switch self { case .rule: "规则"; case .global: "全局"; case .direct: "直连" }
    }
}

enum RouteAction: String, Codable, CaseIterable, Identifiable {
    case direct = "DIRECT"
    case proxy = "PROXY"
    case reject = "REJECT"
    var id: String { rawValue }
}

enum RuleKind: String, Codable, CaseIterable, Identifiable {
    case privateNetwork = "private"
    case domain
    case suffix
    case keyword
    case port
    case category
    case geoIP = "geoip"
    case match
    var id: String { rawValue }
    var title: String {
        switch self {
        case .privateNetwork: "私有网络"
        case .domain: "完整域名"
        case .suffix: "域名后缀"
        case .keyword: "关键字"
        case .port: "目标端口"
        case .category: "流量类别"
        case .geoIP: "服务器地区"
        case .match: "全部匹配"
        }
    }
}

struct ProxyNode: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String
    var host: String
    var port: Int
    var method: String?
    var password: String?
    var username: String?
    var sourceID: String
    var supported: Bool
    var lastLatency: Int?
    var lastError: String?
}

struct SubscriptionProfile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: String
    var updatedAt: Date?
    var nodeIDs: [String]
    var lastError: String?
}

struct RoutingRule: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var kind: RuleKind
    var value: String
    var action: RouteAction
    var enabled: Bool
    var builtIn: Bool
}

struct ConnectionRecord: Identifiable, Hashable {
    var id = UUID()
    var host: String
    var port: Int
    var category: String
    var action: RouteAction
    var rule: String
    var node: String?
    var startedAt = Date()
    var endedAt: Date?
    var uploaded: Int64 = 0
    var downloaded: Int64 = 0
    var status = "活动"
}

struct TrafficSample: Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var upload: Int64
    var download: Int64
}

struct PersistedConfig: Codable {
    var mode: ProxyMode = .rule
    var proxyEnabled = true
    var selectedNodeID: String?
    var proxyPort = 7897
    var nodes: [ProxyNode] = []
    var subscriptions: [SubscriptionProfile] = []
    var customRules: [RoutingRule] = []
}

extension RoutingRule {
    static let builtIns: [RoutingRule] = [
        .init(id: "builtin-private", name: "局域网与本机", kind: .privateNetwork, value: "", action: .direct, enabled: true, builtIn: true),
        .init(id: "builtin-cn-domain", name: "中国域名", kind: .suffix, value: ".cn", action: .direct, enabled: true, builtIn: true),
        .init(id: "builtin-domestic", name: "国内常用服务", kind: .category, value: "domestic", action: .direct, enabled: true, builtIn: true),
        .init(id: "builtin-ai", name: "AI 服务", kind: .category, value: "ai", action: .proxy, enabled: true, builtIn: true),
        .init(id: "builtin-streaming", name: "国际流媒体", kind: .category, value: "streaming", action: .proxy, enabled: true, builtIn: true),
        .init(id: "builtin-social", name: "国际社交", kind: .category, value: "social", action: .proxy, enabled: true, builtIn: true),
        .init(id: "builtin-cn-ip", name: "中国服务器 IP", kind: .geoIP, value: "CN", action: .direct, enabled: true, builtIn: true),
        .init(id: "builtin-overseas-ip", name: "境外服务器 IP", kind: .geoIP, value: "OVERSEAS", action: .proxy, enabled: true, builtIn: true),
        .init(id: "builtin-final", name: "其他国际流量", kind: .match, value: "*", action: .proxy, enabled: true, builtIn: true)
    ]
}
