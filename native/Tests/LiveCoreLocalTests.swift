import Foundation

@main
struct LiveCoreLocalTests {
    static func main() async throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ZhilianNative")
        let directories = try FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Core-") }
            .sorted { left, right in
                let leftDate = (try? left.appendingPathComponent("config.yaml").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.appendingPathComponent("config.yaml").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
        guard let latestDirectory = directories.first else { throw TunnelError.connect("没有找到运行中的核心目录") }
        let yaml = try String(contentsOf: latestDirectory.appendingPathComponent("config.yaml"), encoding: .utf8)
        func value(_ key: String) -> String? { yaml.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }.map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) } }
        guard let controller = value("external-controller"), let secret = value("secret"),
              let portText = controller.split(separator: ":").last, let port = Int(portText),
              let controllerURL = URL(string: "http://127.0.0.1:\(port)/proxies") else {
            throw TunnelError.protocolError("核心配置缺少控制接口")
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
        var request = URLRequest(url: controllerURL)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = json["proxies"] as? [String: Any] else { throw NSError(domain: "local", code: 1) }
        let descriptions = proxies.values.compactMap { $0 as? [String: Any] }
        let anyTLS = descriptions.filter { ($0["type"] as? String)?.lowercased() == "anytls" }.count
        let shadowsocks = descriptions.filter { ($0["type"] as? String)?.lowercased().contains("shadowsocks") == true }.count
        print("PASS: 本机核心鉴权成功，已加载 \(proxies.count) 个对象，AnyTLS=\(anyTLS)，SS=\(shadowsocks)")
    }
}
