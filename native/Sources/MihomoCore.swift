import Foundation

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
    private let lock = NSLock()
    private let controllerSession: URLSession

    private var corePIDURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhilianNative/core.pid")
    }

    init(protocolClasses: [AnyClass]? = nil, executableOverride: URL? = nil) {
        // Every core gets its own local port trio.  It avoids a stale child
        // from an earlier app launch blocking the next launch; AppModel updates
        // macOS system proxy only after this new core has passed readiness.
        let base = 20_000 + (Int(ProcessInfo.processInfo.processIdentifier) % 10_000) * 3
        socksPort = base
        controllerPort = base + 1
        mixedPort = base + 2
        self.executableOverride = executableOverride
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        controllerSession = URLSession(configuration: configuration)
    }

    /// `true` only after both the SOCKS listener and controller listener are accepting connections.
    /// Keeping this stricter than `Process.isRunning` prevents the local HTTP proxy from sending
    /// traffic to a core that has not finished loading the provider yet.
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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhilianNative/Core-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let providers = support.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let localProvider = providers.appendingPathComponent("zhilian.yaml")
        try Data(contentsOf: providerFile).write(to: localProvider, options: .atomic)
        let configURL = support.appendingPathComponent("config.yaml")
        let config = Self.configuration(providerPath: "./providers/zhilian.yaml", socksPort: socksPort,
                                        mixedPort: mixedPort, controllerPort: controllerPort, secret: secret, mode: mode)
        try Data(config.utf8).write(to: configURL, options: .atomic)
        let coreLog = support.appendingPathComponent("core.log")
        try Data().write(to: coreLog, options: .atomic)
        let output = try FileHandle(forWritingTo: coreLog)
        let task = Process()
        task.executableURL = executable
        task.arguments = ["-d", support.path, "-f", configURL.path]
        task.standardOutput = output
        task.standardError = output
        try task.run()
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
            if task.isRunning { task.terminate(); task.waitUntilExit() }
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
        if task?.isRunning == true { task?.terminate() }
        removeRecordedPID(task?.processIdentifier)
        output?.closeFile()
    }

    func stopAndWait() {
        lock.lock(); let task = process; let output = logHandle; process = nil; currentProviderPath = nil; currentMode = nil; logHandle = nil; logURL = nil; lock.unlock()
        if let task, task.isRunning {
            task.terminate()
            task.waitUntilExit()
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

    private func waitUntilAvailable(node: String?) async throws {
        var lastFailure: Error?
        for attempt in 0..<30 {
            do {
                let data = try await request(path: "/proxies/\(Self.escapedPath(Self.groupName))", method: "GET", body: nil)
                if let group = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = group["all"] as? [String] {
                    if node == nil || choices.contains(node!) { return }
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

    private static func configuration(providerPath: String, socksPort: Int, mixedPort: Int, controllerPort: Int, secret: String, mode: ProxyMode) -> String {
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let routingRules: String
        if mode == .global {
            routingRules = "          - MATCH,智连节点"
        } else {
            routingRules = """
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
              enable: true
              url: https://www.gstatic.com/generate_204
              interval: 600
        proxy-groups:
          - name: 智连节点
            type: select
            use:
              - zhilian-subscription
        rules:
        \(routingRules)
        """
    }

    private static func escapedPath(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
}
