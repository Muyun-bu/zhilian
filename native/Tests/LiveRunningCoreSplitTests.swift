import Foundation

/// Exercises the exact core owned by the installed application without
/// starting a competing second core. Both tunnels remain open while the
/// authenticated connection snapshot is inspected.
@main
struct LiveRunningCoreSplitTests {
    static func main() async throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhilianNative", isDirectory: true)
        let directories = try FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("Core-") }
            .sorted { lhs, rhs in
                let left = (try? lhs.appendingPathComponent("config.yaml").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.appendingPathComponent("config.yaml").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        guard let directory = directories.first else { throw TunnelError.connect("没有找到运行中的核心目录") }
        let config = try String(contentsOf: directory.appendingPathComponent("config.yaml"), encoding: .utf8)

        func value(_ key: String) -> String? {
            config.split(separator: "\n")
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }
                .map { line in
                    String(line.split(separator: ":", maxSplits: 1)[1])
                        .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                }
        }

        guard let mixedText = value("mixed-port"), let mixedPort = Int(mixedText),
              let controller = value("external-controller"), let secret = value("secret"),
              let controllerURL = URL(string: "http://\(controller)/connections") else {
            throw TunnelError.protocolError("核心配置缺少端口或控制接口")
        }

        let overseas = try connectThroughHTTPProxy(port: mixedPort, host: "example.com", destinationPort: 443)
        defer { overseas.close() }
        let domestic = try connectThroughHTTPProxy(port: mixedPort, host: "114.114.114.114", destinationPort: 53)
        defer { domestic.close() }
        try? await Task.sleep(nanoseconds: 350_000_000)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.connectionProxyDictionary = [:]
        var request = URLRequest(url: controllerURL, timeoutInterval: 5)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession(configuration: sessionConfiguration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let connections = root["connections"] as? [[String: Any]] else {
            throw TunnelError.protocolError("无法读取核心连接快照")
        }

        func destination(_ connection: [String: Any]) -> String {
            let metadata = connection["metadata"] as? [String: Any] ?? [:]
            let host = metadata["host"] as? String ?? ""
            return host.isEmpty ? (metadata["destinationIP"] as? String ?? "") : host
        }
        func isDirect(_ connection: [String: Any]) -> Bool {
            (connection["chains"] as? [String] ?? []).contains { $0.caseInsensitiveCompare("DIRECT") == .orderedSame }
        }

        guard connections.contains(where: { destination($0) == "example.com" && !isDirect($0) }) else {
            throw TunnelError.protocolError("境外 example.com 没有走代理节点")
        }
        guard connections.contains(where: { destination($0) == "114.114.114.114" && isDirect($0) }) else {
            throw TunnelError.protocolError("中国服务器 IP 没有按规则直连")
        }
        print("PASS: 当前安装版将 example.com 通过节点代理，将 114.114.114.114 直连，真实连接快照可读")
    }

    private static func connectThroughHTTPProxy(port: Int, host: String, destinationPort: Int) throws -> SocketFD {
        let client = try SocketFD.connect(host: "127.0.0.1", port: port, timeout: 15)
        try client.write(Data("CONNECT \(host):\(destinationPort) HTTP/1.1\r\nHost: \(host):\(destinationPort)\r\nProxy-Connection: keep-alive\r\n\r\n".utf8))
        let response = try client.read(max: 4_096)
        let text = String(data: response, encoding: .utf8) ?? ""
        guard text.hasPrefix("HTTP/"), text.contains(" 200 ") else {
            client.close()
            throw TunnelError.protocolError("mixed-port 没有建立目标隧道")
        }
        return client
    }
}
