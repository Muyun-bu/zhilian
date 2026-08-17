import Foundation

@main
struct NativeTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resource = [root.appendingPathComponent("native/Resources/china-ip-ranges.txt"),
                        root.appendingPathComponent("zhilian/native/Resources/china-ip-ranges.txt")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        precondition(resource != nil, "找不到中国 IP 数据库测试资源")
        let database = IPDatabase(resourceURL: resource)
        precondition(database.locate(host: "114.114.114.114") == .cn, "中国 IPv4 判断失败")
        precondition(database.locate(host: "8.8.8.8") == .overseas, "境外 IPv4 判断失败")
        precondition(database.locate(host: "127.0.0.1") == .privateNetwork, "私有地址判断失败")
        precondition(IPDatabase.isPrivate("169.254.1.2"), "链路本地 IPv4 判断失败")
        precondition(IPDatabase.isPrivate("fd00::1"), "私有 IPv6 判断失败")
        precondition(!IPDatabase.isPrivate("fddomain.example"), "普通域名被误判为 IPv6 私网")
        let router = RoutingEngine(database: database)
        let cn = router.decide(host: "114.114.114.114", port: 443, mode: .rule, rules: RoutingRule.builtIns)
        let overseas = router.decide(host: "8.8.8.8", port: 443, mode: .rule, rules: RoutingRule.builtIns)
        precondition(cn.action == .direct, "国内服务器应直连")
        precondition(overseas.action == .proxy, "境外服务器应代理")
        let ssURI = "ss://" + Data("aes-256-gcm:test-password@example.com:8388".utf8).base64EncodedString() + "#测试节点"
        let sample = Data(ssURI.utf8).base64EncodedString()
        let service = SubscriptionService()
        let prepared = try service.prepare(data: Data(sample.utf8), sourceID: "test")
        precondition(prepared.nodes.count == 1 && prepared.nodes[0].supported, "Base64 URI 节点解析失败")
        let provider = try JSONSerialization.jsonObject(with: prepared.document) as? [String: Any]
        precondition((provider?["proxies"] as? [[String: Any]])?.count == 1, "Base64 URI 没有转换为核心 provider 文档")
        let oldBackup = Data("{\"service\":\"Wi-Fi\",\"web\":{\"enabled\":false,\"server\":\"\",\"port\":0},\"secureWeb\":{\"enabled\":false,\"server\":\"\",\"port\":0}}".utf8)
        let decodedBackup = try JSONDecoder().decode(SystemProxyBackup.self, from: oldBackup)
        precondition(decodedBackup.socks == nil, "旧版代理备份兼容失败")
        let oldConnectedConfig = Data("{\"proxyEnabled\":true,\"systemProxyEnabled\":true}".utf8)
        let migratedConnectedConfig = try JSONDecoder().decode(PersistedConfig.self, from: oldConnectedConfig)
        precondition(migratedConnectedConfig.autoConnectOnLaunch, "旧版完整连接状态没有迁移为自动连接")
        let oldCoreOnlyConfig = Data("{\"proxyEnabled\":true,\"systemProxyEnabled\":false}".utf8)
        let migratedCoreOnlyConfig = try JSONDecoder().decode(PersistedConfig.self, from: oldCoreOnlyConfig)
        precondition(!migratedCoreOnlyConfig.autoConnectOnLaunch, "旧版核心单独运行状态不应迁移为完整连接")
        let displayNode = ProxyNode(id: "display", name: "香港 03", type: "anytls", host: "example.com", port: 443,
                                    method: nil, password: nil, username: nil, sourceID: "test", supported: true,
                                    lastLatency: 47, lastError: nil)
        precondition(displayNode.regionLabel == "香港" && displayNode.isSelectableProxy, "节点地区或可选状态计算失败")
        var accountNode = displayNode
        accountNode.name = "剩余流量：18 GB"
        precondition(accountNode.regionLabel == "账户信息" && !accountNode.isSelectableProxy, "账户信息不应作为代理节点显示")
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
        print("PASS: IP 数据库、国内/境外双层分流、节点分类、订阅规范化和旧配置兼容")
    }
}
