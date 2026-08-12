import Foundation

private final class CoreDateParser: @unchecked Sendable {
    private let lock = NSLock()
    private let fractional: ISO8601DateFormatter
    private let standard = ISO8601DateFormatter()

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func date(from value: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: value) ?? standard.date(from: value)
    }
}

final class MihomoCore: @unchecked Sendable {
    private static let providerName = "zhilian-subscription"
    private static let groupName = "智连节点"
    let socksPort: Int
    let controllerPort: Int
    /// HTTP and SOCKS listener owned directly by mihomo. System proxy traffic
    /// must use this port instead of passing through the Swift inspection proxy.
    let mixedPort: Int
    private let secret = UUID().uuidString
    private var process: Process?
    private var currentProviderPath: String?
    private var currentMode: ProxyMode?
    private var logHandle: FileHandle?
    private var logURL: URL?
    private let executableOverride: URL?
    private let chinaIPRuleOverride: URL?
    private let lock = NSLock()
    private let controllerSession: URLSession
    private static let dateParser = CoreDateParser()

    private var supportRoot: URL {
        if executableOverride != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ZhilianCoreTest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhilianNative", isDirectory: true)
    }

    private var corePIDURL: URL { supportRoot.appendingPathComponent("core.pid") }

    init(protocolClasses: [AnyClass]? = nil, executableOverride: URL? = nil, chinaIPRuleOverride: URL? = nil) {
        // Every core gets its own local port trio.  It avoids a stale child
        // from an earlier app launch blocking the next launch; AppModel updates
        // macOS system proxy only after this new core has passed readiness.
        let base = 20_000 + (Int(ProcessInfo.processInfo.processIdentifier) % 10_000) * 3
        socksPort = base
        controllerPort = base + 1
        mixedPort = base + 2
        self.executableOverride = executableOverride
        self.chinaIPRuleOverride = chinaIPRuleOverride
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        controllerSession = URLSession(configuration: configuration)
    }

    /// A process is assigned here only after all three local listeners pass the
    /// startup readiness check. Runtime controller health is monitored by AppModel.
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true }

    func start(providerFile: URL, selectedNode: String?, mode: ProxyMode = .rule, forceReload: Bool = false) throws {
        lock.lock()
        let alreadyRunning = !forceReload && process?.isRunning == true && currentProviderPath == providerFile.path && currentMode == mode
        lock.unlock()
        if alreadyRunning {
            if let selectedNode { Task { try? await self.select(node: selectedNode) } }
            return
        }
        stopAndWait()
        terminateRecordedCore()
        guard let executable = executableOverride ?? Bundle.main.url(forResource: "mihomo", withExtension: nil, subdirectory: "Core") else {
            throw TunnelError.connect("缺少多协议核心")
        }
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        let support = supportRoot.appendingPathComponent("Core-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let providers = support.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let localProvider = providers.appendingPathComponent("zhilian.yaml")
        try Data(contentsOf: providerFile).write(to: localProvider, options: .atomic)
        let rulesDirectory = support.appendingPathComponent("rules", isDirectory: true)
        try FileManager.default.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
        let executableResource = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("china-ip-cidrs.txt")
        let chinaIPSource = chinaIPRuleOverride ?? Bundle.main.url(forResource: "china-ip-cidrs", withExtension: "txt")
            ?? (FileManager.default.fileExists(atPath: executableResource.path) ? executableResource : nil)
        if let chinaIPSource {
            try Data(contentsOf: chinaIPSource).write(to: rulesDirectory.appendingPathComponent("china-ip-cidrs.txt"), options: .atomic)
        }
        let configURL = support.appendingPathComponent("config.yaml")
        let config = Self.configuration(providerPath: "./providers/zhilian.yaml", socksPort: socksPort,
                                        mixedPort: mixedPort, controllerPort: controllerPort, secret: secret, mode: mode,
                                        includeChinaIPRules: chinaIPSource != nil)
        try Data(config.utf8).write(to: configURL, options: .atomic)
        let coreLog = support.appendingPathComponent("core.log")
        try Data().write(to: coreLog, options: .atomic)
        let output = try FileHandle(forWritingTo: coreLog)
        let task = Process()
        task.executableURL = executable
        task.arguments = ["-d", support.path, "-f", configURL.path]
        task.standardOutput = output
        task.standardError = output
        do { try task.run() }
        catch { output.closeFile(); throw error }
        var ready = false
        for _ in 0..<100 {
            let socksReady = (try? SocketFD.connect(host: "127.0.0.1", port: socksPort, timeout: 1)) != nil
            let mixedReady = (try? SocketFD.connect(host: "127.0.0.1", port: mixedPort, timeout: 1)) != nil
            let controllerReady = (try? SocketFD.connect(host: "127.0.0.1", port: controllerPort, timeout: 1)) != nil
            if socksReady && mixedReady && controllerReady { ready = true; break }
            if !task.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard ready, task.isRunning else {
            Self.terminateProcess(task)
            output.closeFile()
            throw TunnelError.connect("多协议核心未能启动。\(Self.startupDiagnostic(from: coreLog))")
        }
        lock.lock()
        process = task
        currentProviderPath = providerFile.path
        currentMode = mode
        logHandle = output
        logURL = coreLog
        lock.unlock()
        try? "\(task.processIdentifier)".write(to: corePIDURL, atomically: true, encoding: .utf8)
        if let selectedNode { Task { try? await self.select(node: selectedNode) } }
    }

    func stop() {
        lock.lock(); let task = process; let output = logHandle; process = nil; currentProviderPath = nil; currentMode = nil; logHandle = nil; logURL = nil; lock.unlock()
        if let task { Self.terminateProcess(task) }
        removeRecordedPID(task?.processIdentifier)
        output?.closeFile()
    }

    func stopAndWait() {
        lock.lock(); let task = process; let output = logHandle; process = nil; currentProviderPath = nil; currentMode = nil; logHandle = nil; logURL = nil; lock.unlock()
        if let task, task.isRunning {
            Self.terminateProcess(task)
        }
        removeRecordedPID(task?.processIdentifier)
        output?.closeFile()
    }

    func select(node: String) async throws {
        try await waitUntilAvailable(node: node)
        let body = try JSONSerialization.data(withJSONObject: ["name": node])
        _ = try await request(path: "/proxies/\(Self.escapedPath(Self.groupName))", method: "PUT", body: body)
    }

    func latency(node: String, target: LatencyTestTarget = .google204, timeoutMilliseconds: Int = 8_000) async throws -> Int {
        try await waitUntilAvailable(node: node)
        let data = try await request(path: Self.providerHealthcheckPath(node: node, target: target, timeoutMilliseconds: timeoutMilliseconds), method: "GET", body: nil, timeout: TimeInterval(timeoutMilliseconds) / 1_000 + 4)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let delay = json?["delay"] as? Int, delay > 0 else { throw TunnelError.connect("测速失败") }
        return delay
    }

    /// Asks mihomo to probe the whole selected group once.  This is both faster and less
    /// error-prone than opening a simultaneous controller request for every provider node.
    func groupLatencies(target: LatencyTestTarget = .google204, timeoutMilliseconds: Int = 8_000) async throws -> [String: Int] {
        try await waitUntilAvailable(node: nil)
        let query = Self.delayQuery(target: target, timeoutMilliseconds: timeoutMilliseconds)
        let path = "/group/\(Self.escapedPath(Self.groupName))/delay?\(query)"
        let data = try await request(path: path, method: "GET", body: nil, timeout: TimeInterval(timeoutMilliseconds) / 1_000 + 8)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TunnelError.connect("核心返回的测速结果无效")
        }
        return json.reduce(into: [:]) { result, entry in
            if let delay = entry.value as? Int, delay > 0 { result[entry.key] = delay }
        }
    }

    /// Returns the actual traffic and active connections handled by mihomo.
    /// The production system proxy points directly at `mixedPort`, so these
    /// values are authoritative while rule/global mode is running.
    func connectionSnapshot() async throws -> CoreConnectionSnapshot {
        let data = try await request(path: "/connections", method: "GET", body: nil, timeout: 3)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TunnelError.connect("核心连接数据无效")
        }
        let uploadTotal = Self.int64(root["uploadTotal"])
        let downloadTotal = Self.int64(root["downloadTotal"])
        let memory = Self.int64(root["memory"])
        let records = (root["connections"] as? [[String: Any]] ?? []).prefix(500).compactMap(Self.connectionRecord)
        return .init(uploadTotal: uploadTotal, downloadTotal: downloadTotal, memory: memory, connections: records)
    }

    /// Verifies that the provider has populated the selector with at least one
    /// usable node, rather than merely accepting the top-level YAML syntax.
    func validateProviderLoaded() async throws {
        try await waitUntilAvailable(node: nil)
    }

    private func waitUntilAvailable(node: String?) async throws {
        var lastFailure: Error?
        for attempt in 0..<30 {
            do {
                let data = try await request(path: "/proxies/\(Self.escapedPath(Self.groupName))", method: "GET", body: nil)
                if let group = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = group["all"] as? [String] {
                    if let node {
                        if choices.contains(node) { return }
                    } else if !choices.isEmpty { return }
                }
            } catch { lastFailure = error }
            if attempt < 29 { try? await Task.sleep(nanoseconds: 250_000_000) }
        }
        if let lastFailure { throw lastFailure }
        throw TunnelError.connect(node == nil ? "核心尚未加载节点组，请更新订阅后重试" : "核心尚未加载该节点，请更新订阅后重试")
    }

    private func request(path: String, method: String, body: Data?, timeout: TimeInterval = 12) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(controllerPort)\(path)") else { throw TunnelError.connect("核心接口无效") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await controllerSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw TunnelError.connect(message ?? "核心请求失败")
        }
        return data
    }

    private static func configuration(providerPath: String, socksPort: Int, mixedPort: Int, controllerPort: Int, secret: String, mode: ProxyMode, includeChinaIPRules: Bool) -> String {
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let chinaIPRule = includeChinaIPRules ? "\n          - RULE-SET,zhilian-cn-ip,DIRECT" : ""
        let ruleProviders = includeChinaIPRules ? """
        rule-providers:
          zhilian-cn-ip:
            type: file
            behavior: ipcidr
            format: text
            path: ./rules/china-ip-cidrs.txt
        """ : ""
        let routingRules: String
        if mode == .global {
            routingRules = "          - MATCH,智连节点"
        } else {
            routingRules = """
                      - DOMAIN,localhost,DIRECT
                      - DOMAIN-SUFFIX,local,DIRECT
                      - IP-CIDR,127.0.0.0/8,DIRECT
                      - IP-CIDR,10.0.0.0/8,DIRECT
                      - IP-CIDR,172.16.0.0/12,DIRECT
                      - IP-CIDR,192.168.0.0/16,DIRECT
                      - IP-CIDR,169.254.0.0/16,DIRECT
                      - IP-CIDR6,::1/128,DIRECT
                      - IP-CIDR6,fc00::/7,DIRECT
                      - IP-CIDR6,fe80::/10,DIRECT
                      - DOMAIN-SUFFIX,cn,DIRECT
                      - DOMAIN-SUFFIX,baidu.com,DIRECT
                      - DOMAIN-SUFFIX,qq.com,DIRECT
                      - DOMAIN-SUFFIX,wechat.com,DIRECT
                      - DOMAIN-SUFFIX,weixin.qq.com,DIRECT
                      - DOMAIN-SUFFIX,taobao.com,DIRECT
                      - DOMAIN-SUFFIX,tmall.com,DIRECT
                      - DOMAIN-SUFFIX,jd.com,DIRECT
                      - DOMAIN-SUFFIX,bilibili.com,DIRECT
                      - DOMAIN-SUFFIX,douyin.com,DIRECT
                      - DOMAIN-SUFFIX,zhihu.com,DIRECT
                      - DOMAIN-SUFFIX,weibo.com,DIRECT
                      - DOMAIN-SUFFIX,aliyun.com,DIRECT
                      - DOMAIN-SUFFIX,163.com,DIRECT
                      - DOMAIN-SUFFIX,xiaomi.com,DIRECT
                      - DOMAIN-SUFFIX,meituan.com,DIRECT
                      - DOMAIN-SUFFIX,amap.com,DIRECT
                      - DOMAIN-SUFFIX,alipay.com,DIRECT
                      - DOMAIN-SUFFIX,openai.com,智连节点
                      - DOMAIN-SUFFIX,chatgpt.com,智连节点
                      - DOMAIN-SUFFIX,anthropic.com,智连节点
                      - DOMAIN-SUFFIX,claude.ai,智连节点
                      - DOMAIN-SUFFIX,perplexity.ai,智连节点
                      - DOMAIN-SUFFIX,huggingface.co,智连节点
                      - DOMAIN-SUFFIX,midjourney.com,智连节点
                      - DOMAIN-SUFFIX,youtube.com,智连节点
                      - DOMAIN-SUFFIX,netflix.com,智连节点
                      - DOMAIN-SUFFIX,spotify.com,智连节点
                      - DOMAIN-SUFFIX,hulu.com,智连节点
                      - DOMAIN-SUFFIX,disneyplus.com,智连节点
                      - DOMAIN-SUFFIX,twitch.tv,智连节点
                      - DOMAIN-SUFFIX,vimeo.com,智连节点
                      - DOMAIN-SUFFIX,twitter.com,智连节点
                      - DOMAIN-SUFFIX,x.com,智连节点
                      - DOMAIN-SUFFIX,facebook.com,智连节点
                      - DOMAIN-SUFFIX,instagram.com,智连节点
                      - DOMAIN-SUFFIX,telegram.org,智连节点
                      - DOMAIN-SUFFIX,reddit.com,智连节点
                      - DOMAIN-SUFFIX,discord.com,智连节点\(chinaIPRule)
                      - MATCH,智连节点
            """
        }
        return """
        socks-port: \(socksPort)
        mixed-port: \(mixedPort)
        allow-lan: false
        bind-address: 127.0.0.1
        mode: rule
        log-level: warning
        external-controller: 127.0.0.1:\(controllerPort)
        secret: \(quoted(secret))
        proxy-providers:
          zhilian-subscription:
            type: file
            path: \(quoted(providerPath))
            exclude-filter: '剩余流量|套餐到期|到期时间'
            health-check:
              enable: false
              url: https://www.gstatic.com/generate_204
              interval: 600
        proxy-groups:
          - name: 智连节点
            type: select
            use:
              - zhilian-subscription
        \(ruleProviders)
        rules:
        \(routingRules)
        """
    }

    private static func escapedPath(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func connectionRecord(_ item: [String: Any]) -> ConnectionRecord? {
        guard let identifier = item["id"] as? String, let id = UUID(uuidString: identifier) else { return nil }
        let metadata = item["metadata"] as? [String: Any] ?? [:]
        let host = nonEmpty(metadata["host"]) ?? nonEmpty(metadata["destinationIP"]) ?? "未知目标"
        let port = int(metadata["destinationPort"])
        let rule = nonEmpty(item["rule"]) ?? "MATCH"
        let rulePayload = nonEmpty(item["rulePayload"])
        let chains = item["chains"] as? [String] ?? []
        let isDirect = chains.contains(where: { $0.caseInsensitiveCompare("DIRECT") == .orderedSame })
        let action: RouteAction = isDirect ? .direct : .proxy
        let node = chains.first(where: { $0 != Self.groupName && $0.caseInsensitiveCompare("DIRECT") != .orderedSame })
        let startedAt = parseDate(nonEmpty(item["start"])) ?? Date()
        let network = (nonEmpty(metadata["network"]) ?? "other").uppercased()
        let connectionType = nonEmpty(metadata["type"])
        let category = trafficCategory(host: host, fallback: connectionType.map { "\(network)/\($0.uppercased())" } ?? network)
        return .init(id: id, host: host, port: port, category: category, action: action,
                     rule: rulePayload.map { "\(rule) · \($0)" } ?? rule, node: node,
                     startedAt: startedAt, endedAt: nil, uploaded: int64(item["upload"]),
                     downloaded: int64(item["download"]), status: "活动")
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func trafficCategory(host: String, fallback: String) -> String {
        let domain = host.lowercased()
        let groups: [(String, [String])] = [
            ("国内", ["baidu.com", "qq.com", "wechat.com", "weixin.qq.com", "taobao.com", "tmall.com", "jd.com", "bilibili.com", "douyin.com", "zhihu.com", "weibo.com", "aliyun.com", "163.com", "xiaomi.com", "meituan.com", "amap.com", "alipay.com"]),
            ("AI", ["openai.com", "chatgpt.com", "anthropic.com", "claude.ai", "perplexity.ai", "huggingface.co", "midjourney.com"]),
            ("流媒体", ["youtube.com", "netflix.com", "spotify.com", "hulu.com", "disneyplus.com", "twitch.tv", "vimeo.com"]),
            ("社交", ["twitter.com", "x.com", "facebook.com", "instagram.com", "telegram.org", "reddit.com", "discord.com"])
        ]
        return groups.first { _, suffixes in suffixes.contains { domain == $0 || domain.hasSuffix("." + $0) } }?.0 ?? fallback
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return dateParser.date(from: value)
    }

    private static func delayQuery(target: LatencyTestTarget = .google204, timeoutMilliseconds: Int = 8_000) -> String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "timeout", value: "\(min(30_000, max(1_000, timeoutMilliseconds)))"),
            URLQueryItem(name: "url", value: target.url)
        ]
        return components.percentEncodedQuery ?? "timeout=8000"
    }

    private static func providerHealthcheckPath(node: String, target: LatencyTestTarget, timeoutMilliseconds: Int) -> String {
        "/providers/proxies/\(escapedPath(providerName))/\(escapedPath(node))/healthcheck?\(delayQuery(target: target, timeoutMilliseconds: timeoutMilliseconds))"
    }

    private static func startupDiagnostic(from logURL: URL) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "请检查订阅格式或端口占用" }
        let lastLines = text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " · ")
        return lastLines.isEmpty ? "请检查订阅格式或端口占用" : lastLines
    }

    /// A normal app exit can leave a child core adopted by launchd before
    /// AppKit delivers its termination notification. Record and reclaim only
    /// our own previous PID, preventing a stale core from blocking fixed ports.
    private func terminateRecordedCore() {
        guard let text = try? String(contentsOf: corePIDURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        guard Self.isZhilianCore(pid: pid) else { try? FileManager.default.removeItem(at: corePIDURL); return }
        _ = Darwin.kill(pid, SIGTERM)
        for _ in 0..<20 {
            if Darwin.kill(pid, 0) != 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: corePIDURL)
    }

    private func removeRecordedPID(_ pid: Int32?) {
        guard let pid,
              let text = try? String(contentsOf: corePIDURL, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines) == "\(pid)" else { return }
        try? FileManager.default.removeItem(at: corePIDURL)
    }

    private static func isZhilianCore(pid: Int32) -> Bool {
        let task = Process(); let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "command="]
        task.standardOutput = output
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        let command = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return command.contains("/Applications/智连.app/Contents/Resources/Core/mihomo") || command.contains("ZhilianNative/Core-")
    }

    private static func terminateProcess(_ task: Process) {
        if task.isRunning {
            task.terminate()
            for _ in 0..<40 {
                if !task.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if task.isRunning { _ = Darwin.kill(task.processIdentifier, SIGKILL) }
        }
        task.waitUntilExit()
    }
}
