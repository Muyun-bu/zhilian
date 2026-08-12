import Foundation
import CryptoKit

enum SubscriptionError: LocalizedError {
    case invalidURL, empty, unsupported
    var errorDescription: String? {
        switch self {
        case .invalidURL: "订阅地址无效"
        case .empty: "订阅没有返回内容"
        case .unsupported: "没有识别到支持的节点"
        }
    }
}

struct SubscriptionService {
    struct Result { let nodes: [ProxyNode]; let document: Data }

    func fetch(url: String, sourceID: String) async throws -> [ProxyNode] {
        try await fetchResult(url: url, sourceID: sourceID).nodes
    }

    func fetchResult(url: String, sourceID: String) async throws -> Result {
        guard let endpoint = URL(string: url), ["http", "https"].contains(endpoint.scheme?.lowercased() ?? "") else {
            throw SubscriptionError.invalidURL
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        // The provider serves a reduced legacy list to unknown clients. ClashMeta
        // requests the complete YAML document, including AnyTLS and modern nodes.
        request.setValue("ClashMeta", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty else { throw SubscriptionError.empty }
        let nodes = parse(data: data, sourceID: sourceID)
        guard !nodes.isEmpty else { throw SubscriptionError.unsupported }
        return Result(nodes: nodes, document: data)
    }

    func parse(data: Data, sourceID: String) -> [ProxyNode] {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            let list: [[String: Any]]
            if let array = json as? [[String: Any]] { list = array }
            else if let object = json as? [String: Any] { list = (object["nodes"] ?? object["proxies"]) as? [[String: Any]] ?? [] }
            else { list = [] }
            let nodes = list.compactMap { node(from: $0, sourceID: sourceID) }
            if !nodes.isEmpty { return nodes }
        }

        let raw = String(data: data, encoding: .utf8) ?? ""
        let text: String
        if raw.contains("://") || raw.contains("proxies:") { text = raw }
        else if let decoded = decodeBase64(raw), let string = String(data: decoded, encoding: .utf8) { text = string }
        else { text = raw }

        let uriNodes = text.split(whereSeparator: \.isNewline).compactMap { parseURI(String($0), sourceID: sourceID) }
        if !uriNodes.isEmpty { return uriNodes }
        return parseClashYAML(text, sourceID: sourceID)
    }

    private func parseURI(_ rawLine: String, sourceID: String) -> ProxyNode? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ss://") { return parseSS(line, sourceID: sourceID) }
        guard let url = URL(string: line), let scheme = url.scheme?.lowercased(), ["http", "socks5"].contains(scheme),
              let host = url.host, let port = url.port else { return nil }
        let name = url.fragment?.removingPercentEncoding ?? "\(scheme.uppercased()) \(host):\(port)"
        return ProxyNode(id: stableID([sourceID, scheme, host, "\(port)", name]), name: name, type: scheme,
                         host: host, port: port, method: nil, password: url.password, username: url.user,
                         sourceID: sourceID, supported: true)
    }

    private func parseSS(_ line: String, sourceID: String) -> ProxyNode? {
        var body = String(line.dropFirst(5))
        let parts = body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        body = String(parts[0]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? body
        let name = parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? "SS 节点" : "SS 节点"
        var credentials = ""
        var server = ""
        if let at = body.lastIndex(of: "@") {
            credentials = decodeBase64String(String(body[..<at])) ?? String(body[..<at])
            server = String(body[body.index(after: at)...])
        } else if let decoded = decodeBase64String(body), let at = decoded.lastIndex(of: "@") {
            credentials = String(decoded[..<at]); server = String(decoded[decoded.index(after: at)...])
        }
        guard let colon = credentials.firstIndex(of: ":") else { return nil }
        let method = String(credentials[..<colon])
        let password = String(credentials[credentials.index(after: colon)...])
        let host: String
        let port: Int
        if server.hasPrefix("["), let end = server.firstIndex(of: "]") {
            host = String(server[server.index(after: server.startIndex)..<end])
            port = Int(server[server.index(end, offsetBy: 2)...]) ?? 0
        } else if let split = server.lastIndex(of: ":") {
            host = String(server[..<split]); port = Int(server[server.index(after: split)...]) ?? 0
        } else { return nil }
        guard !host.isEmpty, port > 0 else { return nil }
        let supported = method == "chacha20-ietf-poly1305"
        return ProxyNode(id: stableID([sourceID, method, host, "\(port)", name]), name: name, type: "ss", host: host,
                         port: port, method: method, password: password, username: nil, sourceID: sourceID, supported: supported)
    }

    private func parseClashYAML(_ text: String, sourceID: String) -> [ProxyNode] {
        var records: [[String: String]] = []
        var current: [String: String] = [:]
        var insideProxies = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "proxies:" { insideProxies = true; continue }
            if insideProxies, let first = raw.first, !first.isWhitespace { break }
            guard insideProxies else { continue }
            if line.hasPrefix("- {") {
                if !current.isEmpty { records.append(current); current = [:] }
                let start = line.index(line.startIndex, offsetBy: 2)
                let body = String(line[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
                records.append(parseInlineYAMLMap(body))
            } else if line.hasPrefix("- name:") {
                if !current.isEmpty { records.append(current) }
                current = ["name": cleanYAML(String(line.dropFirst(7)))]
            } else if !current.isEmpty, let colon = line.firstIndex(of: ":") {
                current[String(line[..<colon])] = cleanYAML(String(line[line.index(after: colon)...]))
            }
        }
        if !current.isEmpty { records.append(current) }
        return records.compactMap { node(from: $0, sourceID: sourceID) }
    }

    private func parseInlineYAMLMap(_ body: String) -> [String: String] {
        var fields: [String] = [], current = "", quote: Character?, depth = 0
        for character in body {
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character; current.append(character)
            } else if character == "[" || character == "{" {
                depth += 1; current.append(character)
            } else if character == "]" || character == "}" {
                depth -= 1; current.append(character)
            } else if character == "," && depth == 0 {
                fields.append(current); current = ""
            } else { current.append(character) }
        }
        if !current.isEmpty { fields.append(current) }
        return fields.reduce(into: [String: String]()) { result, field in
            guard let colon = field.firstIndex(of: ":") else { return }
            let key = String(field[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(field[field.index(after: colon)...])
            result[key] = cleanYAML(value)
        }
    }

    private func node(from dictionary: [String: Any], sourceID: String) -> ProxyNode? {
        let strings = dictionary.reduce(into: [String: String]()) { result, entry in result[entry.key] = String(describing: entry.value) }
        return node(from: strings, sourceID: sourceID)
    }

    private func node(from d: [String: String], sourceID: String) -> ProxyNode? {
        guard let type = d["type"]?.lowercased(), let host = d["server"] ?? d["host"], let port = Int(d["port"] ?? "") else { return nil }
        let name = d["name"] ?? "\(type.uppercased()) \(host):\(port)"
        let method = d["cipher"] ?? d["method"]
        let supportedTypes = ["http", "socks5", "ss", "anytls", "vmess", "vless", "trojan", "hysteria2", "tuic", "wireguard"]
        let accountInformation = ["剩余流量", "套餐到期", "到期时间"].contains { name.contains($0) }
        let supported = supportedTypes.contains(type) && !accountInformation
        return ProxyNode(id: stableID([sourceID, type, host, "\(port)", name]), name: name, type: type, host: host, port: port,
                         method: method, password: d["password"], username: d["username"], sourceID: sourceID, supported: supported)
    }

    private func stableID(_ fields: [String]) -> String {
        let digest = SHA256.hash(data: Data(fields.joined(separator: "|").utf8))
        return "node-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func decodeBase64String(_ value: String) -> String? {
        decodeBase64(value).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func decodeBase64(_ value: String) -> Data? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized, options: .ignoreUnknownCharacters)
    }

    private func cleanYAML(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
