import Foundation

struct RouteDecision {
    let action: RouteAction
    let category: String
    let location: IPLocation
    let reason: String
}

final class RoutingEngine {
    private let database: IPDatabase
    private let categories: [String: [String]] = [
        "domestic": ["baidu.com", "qq.com", "wechat.com", "weixin.qq.com", "taobao.com", "tmall.com", "jd.com", "bilibili.com", "douyin.com", "zhihu.com", "weibo.com", "aliyun.com", "163.com", "xiaomi.com", "meituan.com", "amap.com", "alipay.com"],
        "ai": ["openai.com", "chatgpt.com", "anthropic.com", "claude.ai", "perplexity.ai", "huggingface.co", "midjourney.com"],
        "streaming": ["youtube.com", "netflix.com", "spotify.com", "hulu.com", "disneyplus.com", "twitch.tv", "vimeo.com"],
        "social": ["twitter.com", "x.com", "facebook.com", "instagram.com", "telegram.org", "reddit.com", "discord.com"]
    ]

    init(database: IPDatabase) { self.database = database }

    func decide(host: String, port: Int, mode: ProxyMode, rules: [RoutingRule]) -> RouteDecision {
        if mode == .direct { return .init(action: .direct, category: category(host), location: .unknown, reason: "直连模式") }
        if mode == .global { return .init(action: .proxy, category: category(host), location: .unknown, reason: "全局模式") }
        let category = category(host)
        let location = database.locate(host: host)
        for rule in rules where rule.enabled {
            let matches: Bool
            switch rule.kind {
            case .privateNetwork: matches = location == .privateNetwork
            case .domain: matches = host.caseInsensitiveCompare(rule.value) == .orderedSame
            case .suffix: matches = host.lowercased().hasSuffix(rule.value.lowercased())
            case .keyword: matches = host.lowercased().contains(rule.value.lowercased())
            case .port: matches = Int(rule.value) == port
            case .category: matches = category == rule.value.lowercased()
            case .geoIP: matches = (rule.value.uppercased() == "CN" && location == .cn) || (rule.value.uppercased() == "OVERSEAS" && location == .overseas)
            case .match: matches = true
            }
            if matches { return .init(action: rule.action, category: category, location: location, reason: rule.name) }
        }
        return .init(action: location == .cn ? .direct : .proxy, category: category, location: location, reason: "服务器地区判断")
    }

    func category(_ host: String) -> String {
        let domain = host.lowercased()
        for (name, suffixes) in categories where suffixes.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) { return name }
        return "other"
    }
}
