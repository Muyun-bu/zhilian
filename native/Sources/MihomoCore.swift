import Foundation

final class MihomoCore: @unchecked Sendable {
    private static let providerName = "zhilian-subscription"
    private static let groupName = "智连节点"
    let socksPort: Int
    let controllerPort: Int
    private let secret = UUID().uuidString
    private var process: Process?
    private var currentProviderPath: String?
    private var logHandle: FileHandle?
    private var logURL: URL?
    private let executableOverride: URL?
    private let lock = NSLock()
    private let controllerSession: URLSession

    init(protocolClasses: [AnyClass]? = nil, executableOverride: URL? = nil) {
        let base = 20_000 + (Int(ProcessInfo.processInfo.processIdentifier) % 10_000) * 2
        socksPort = base
        controllerPort = base + 1
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

    func start(providerFile: URL, selectedNode: String?, forceReload: Bool = false) throws {
        lock.lock()
        let alreadyRunning = !forceReload && process?.isRunning == true && currentProviderPath == providerFile.path
        lock.unlock()
        if alreadyRunning {
            if let selectedNode { Task { try? await self.select(node: selectedNode) } }
            return
        }
        stopAndWait()
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
                                        controllerPort: controllerPort, secret: secret)
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
            let controllerReady = (try? SocketFD.connect(host: "127.0.0.1", port: controllerPort, timeout: 1)) != nil
            if socksReady && controllerReady { ready = true; break }
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
        logHandle = output
        logURL = coreLog
        lock.unlock()
        if let selectedNode { Task { try? await self.select(node: selectedNode) } }
    }

    func stop() {
        lock.lock(); let task = process; let output = logHandle; process = nil; currentProviderPath = nil; logHandle = nil; logURL = nil; lock.unlock()
        if task?.isRunning == true { task?.terminate() }
        output?.closeFile()
    }

    func stopAndWait() {
        lock.lock(); let task = process; let output = logHandle; process = nil; currentProviderPath = nil; logHandle = nil; logURL = nil; lock.unlock()
        if let task, task.isRunning {
            task.terminate()
            task.waitUntilExit()
        }
        output?.closeFile()
    }

    func select(node: String) async throws {
        try await waitUntilAvailable(node: node)
        let body = try JSONSerialization.data(withJSONObject: ["name": node])
        _ = try await request(path: "/proxies/\(Self.escapedPath(Self.groupName))", method: "PUT", body: body)
    }

    func latency(node: String) async throws -> Int {
        try await waitUntilAvailable(node: node)
        let data = try await request(path: Self.providerHealthcheckPath(node: node), method: "GET", body: nil, timeout: 12)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let delay = json?["delay"] as? Int, delay > 0 else { throw TunnelError.connect("测速失败") }
        return delay
    }

    /// Asks mihomo to probe the whole selected group once.  This is both faster and less
    /// error-prone than opening a simultaneous controller request for every provider node.
    func groupLatencies() async throws -> [String: Int] {
        try await waitUntilAvailable(node: nil)
        let query = Self.delayQuery()
        let path = "/group/\(Self.escapedPath(Self.groupName))/delay?\(query)"
        let data = try await request(path: path, method: "GET", body: nil, timeout: 20)
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

    private static func configuration(providerPath: String, socksPort: Int, controllerPort: Int, secret: String) -> String {
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        return """
        socks-port: \(socksPort)
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
          - MATCH,智连节点
        """
    }

    private static func escapedPath(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func delayQuery() -> String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "timeout", value: "8000"),
            URLQueryItem(name: "url", value: "https://www.gstatic.com/generate_204")
        ]
        return components.percentEncodedQuery ?? "timeout=8000"
    }

    private static func providerHealthcheckPath(node: String) -> String {
        "/providers/proxies/\(escapedPath(providerName))/\(escapedPath(node))/healthcheck?\(delayQuery())"
    }

    private static func startupDiagnostic(from logURL: URL) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "请检查订阅格式或端口占用" }
        let lastLines = text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " · ")
        return lastLines.isEmpty ? "请检查订阅格式或端口占用" : lastLines
    }
}
