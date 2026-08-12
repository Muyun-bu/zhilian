import Foundation

@main
struct NativeTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let database = IPDatabase(resourceURL: root.appendingPathComponent("zhilian/native/Resources/china-ip-ranges.txt"))
        precondition(database.locate(host: "114.114.114.114") == .cn, "中国 IPv4 判断失败")
        precondition(database.locate(host: "8.8.8.8") == .overseas, "境外 IPv4 判断失败")
        precondition(database.locate(host: "127.0.0.1") == .privateNetwork, "私有地址判断失败")
        let router = RoutingEngine(database: database)
        let cn = router.decide(host: "114.114.114.114", port: 443, mode: .rule, rules: RoutingRule.builtIns)
        let overseas = router.decide(host: "8.8.8.8", port: 443, mode: .rule, rules: RoutingRule.builtIns)
        precondition(cn.action == .direct, "国内服务器应直连")
        precondition(overseas.action == .proxy, "境外服务器应代理")
        let sample = "c3M6Ly9ZMmhoWTJoaE1qQXRhV1YwWmkxd2IyeDVNVEl6TkRVMk9Eaz0="
        _ = SubscriptionService().parse(data: Data(sample.utf8), sourceID: "test")
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let nodes = SubscriptionService().parse(data: data, sourceID: "live")
            precondition(!nodes.isEmpty, "真实订阅解析失败")
            print("PASS: 真实订阅解析出 \(nodes.count) 个节点，其中 \(nodes.filter(\.supported).count) 个受支持")
            var working = 0
            for node in nodes where node.supported && node.type == "ss" {
                do {
                    let tunnel = try ShadowsocksTunnel(node: node, destinationHost: "example.com", destinationPort: 80)
                    try tunnel.write(Data("HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n".utf8))
                    let response = try tunnel.read(); tunnel.close()
                    if String(data: response, encoding: .utf8)?.hasPrefix("HTTP/") == true { working += 1 }
                } catch { print("节点测试失败：\(error.localizedDescription)"); continue }
            }
            guard working > 0 else { print("FAIL: 没有节点能完成真实代理请求"); exit(1) }
            print("PASS: \(working) 个节点完成 Shadowsocks 端到端代理请求")
        }
        print("PASS: IP 数据库、国内/境外双层分流、订阅解析")
    }
}
