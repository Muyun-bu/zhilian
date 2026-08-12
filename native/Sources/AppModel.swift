import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var config: PersistedConfig
    @Published var running = false
    @Published var systemProxy = false
    @Published var connections: [ConnectionRecord] = []
    @Published var samples: [TrafficSample] = []
    @Published var totalUpload: Int64 = 0
    @Published var totalDownload: Int64 = 0
    @Published var notice: String?
    @Published var busy = false
    @Published var testingAll = false
    let store = ConfigStore()
    private let server: ProxyServer
    private let subscriptionService = SubscriptionService()
    private let core = MihomoCore()
    private var previousUpload: Int64 = 0
    private var previousDownload: Int64 = 0
    private var timer: Timer?

    var rules: [RoutingRule] { RoutingRule.builtIns + config.customRules }
    var selectedNode: ProxyNode? { config.nodes.first { $0.id == config.selectedNodeID } }

    init() {
        config = ConfigStore().load()
        let ipURL = Bundle.main.url(forResource: "china-ip-ranges", withExtension: "txt")
        let router = RoutingEngine(database: IPDatabase(resourceURL: ipURL))
        server = ProxyServer(router: router)
        server.context = { [weak self] in
            guard let self else { return .init(mode: .rule, rules: RoutingRule.builtIns, node: nil, coreSocksPort: nil) }
            return DispatchQueue.main.sync { .init(mode: self.config.mode, rules: self.rules, node: self.selectedNode, coreSocksPort: self.core.isRunning ? self.core.socksPort : nil) }
        }
        server.onOpen = { [weak self] id, host, port, decision, node in Task { @MainActor in
            self?.connections.insert(.init(id: id, host: host, port: port, category: decision.category, action: decision.action, rule: decision.reason, node: node), at: 0)
            if (self?.connections.count ?? 0) > 300 { self?.connections.removeLast() }
        }}
        server.onTraffic = { [weak self] id, up, down in Task { @MainActor in
            guard let self else { return }; self.totalUpload += up; self.totalDownload += down
            if let index = self.connections.firstIndex(where: { $0.id == id }) { self.connections[index].uploaded += up; self.connections[index].downloaded += down }
        }}
        server.onClose = { [weak self] id, error in Task { @MainActor in
            if let index = self?.connections.firstIndex(where: { $0.id == id }) { self?.connections[index].endedAt = Date(); self?.connections[index].status = error == nil ? "完成" : "失败" }
        }}
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.sampleTraffic() } }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.server.stop(); self?.core.stopAndWait(); if self?.systemProxy == true { self?.setSystemProxy(false) } }
        }
        if !config.subscriptions.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                for subscription in self.config.subscriptions { await self.refreshSubscription(subscription.id) }
                if self.config.proxyEnabled && !self.running { self.start() }
            }
        } else if config.proxyEnabled {
            start()
        }
    }

    func start() {
        if let subscription = config.subscriptions.first {
            let cache = providerCacheURL(subscription.id)
            guard FileManager.default.fileExists(atPath: cache.path) else {
                notice = "正在更新订阅，完成后自动启动代理"
                Task { [weak self] in
                    guard let self else { return }
                    await self.refreshSubscription(subscription.id)
                    if self.config.subscriptions.first?.lastError == nil { self.start() }
                }
                return
            }
            do { try core.start(providerFile: cache, selectedNode: selectedNode?.name) }
            catch { notice = error.localizedDescription; return }
        } else if config.mode != .direct {
            notice = "请先添加并更新订阅，再启动代理"
            return
        }
        let requestedPort = config.proxyPort
        for port in requestedPort...(requestedPort + 20) {
            do {
                try server.start(port: port)
                config.proxyPort = port; running = true; config.proxyEnabled = true; save()
                if port != requestedPort { notice = "端口 \(requestedPort) 被占用，已自动切换到 \(port)" }
                return
            } catch { continue }
        }
        running = false; config.proxyEnabled = false; notice = "无法找到可用的本地代理端口"
    }
    func stop() { if systemProxy { setSystemProxy(false) }; server.stop(); core.stopAndWait(); running = false; config.proxyEnabled = false; save() }
    func toggleServer() { running ? stop() : start() }
    func save() { store.save(config) }

    func addSubscription(name: String, url: String) async {
        let profile = SubscriptionProfile(id: UUID().uuidString, name: name.isEmpty ? "我的订阅" : name, url: url, updatedAt: nil, nodeIDs: [], lastError: nil)
        config.subscriptions.append(profile); save(); await refreshSubscription(profile.id)
    }
    func refreshSubscription(_ id: String) async {
        guard let index = config.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        busy = true
        do {
            let result = try await subscriptionService.fetchResult(url: config.subscriptions[index].url, sourceID: id)
            let nodes = result.nodes
            try result.document.write(to: providerCacheURL(id), options: .atomic)
            config.nodes.removeAll { $0.sourceID == id }; config.nodes.append(contentsOf: nodes)
            config.subscriptions[index].nodeIDs = nodes.map(\.id); config.subscriptions[index].updatedAt = Date(); config.subscriptions[index].lastError = nil
            if config.selectedNodeID == nil { config.selectedNodeID = nodes.first(where: \.supported)?.id }
            notice = "已更新 \(nodes.count) 个节点"
        } catch { config.subscriptions[index].lastError = error.localizedDescription; notice = error.localizedDescription }
        busy = false; save()
        if running, let subscription = config.subscriptions.first {
            do { try core.start(providerFile: providerCacheURL(subscription.id), selectedNode: selectedNode?.name, forceReload: true) }
            catch { notice = "核心重载失败：\(error.localizedDescription)" }
        }
    }
    func removeSubscription(_ id: String) { config.nodes.removeAll { $0.sourceID == id }; config.subscriptions.removeAll { $0.id == id }; if !config.nodes.contains(where: { $0.id == config.selectedNodeID }) { config.selectedNodeID = nil }; save() }

    func testNode(_ id: String) async {
        guard let node = config.nodes.first(where: { $0.id == id }) else { return }
        guard node.supported else { return }
        if !core.isRunning, let subscription = config.subscriptions.first {
            do { try core.start(providerFile: providerCacheURL(subscription.id), selectedNode: selectedNode?.name) }
            catch { notice = error.localizedDescription; return }
        }
        let started = Date(); var latency: Int?; var failure: String?
        do {
            if core.isRunning {
                latency = try await core.latency(node: node.name)
            } else {
                let tunnel: Tunnel = node.type == "ss" ? try ShadowsocksTunnel(node: node, destinationHost: "www.apple.com", destinationPort: 443) : try SocketFD.connect(host: node.host, port: node.port)
                tunnel.close(); latency = Int(Date().timeIntervalSince(started) * 1000)
            }
        } catch { failure = error.localizedDescription }
        guard let index = config.nodes.firstIndex(where: { $0.id == id }) else { return }
        config.nodes[index].lastLatency = latency; config.nodes[index].lastError = failure
        save()
    }

    func selectNode(_ id: String) async {
        guard let node = config.nodes.first(where: { $0.id == id }), node.supported else { return }
        if core.isRunning {
            do {
                try await core.select(node: node.name)
            } catch {
                notice = "节点切换失败：\(error.localizedDescription)"
                return
            }
        }
        config.selectedNodeID = id; save()
    }

    func testAllNodes(ids: [String]? = nil) async {
        guard !testingAll else { return }
        if !core.isRunning, let subscription = config.subscriptions.first {
            do { try core.start(providerFile: providerCacheURL(subscription.id), selectedNode: selectedNode?.name) }
            catch { notice = error.localizedDescription; return }
        }
        testingAll = true
        let targets = config.nodes.filter { $0.supported && (ids == nil || ids!.contains($0.id)) }
        guard !targets.isEmpty else { testingAll = false; notice = "没有可测速的节点"; return }
        do {
            let latencies = try await core.groupLatencies()
            for node in targets {
                guard let index = config.nodes.firstIndex(where: { $0.id == node.id }) else { continue }
                config.nodes[index].lastLatency = latencies[node.name]
                config.nodes[index].lastError = latencies[node.name] == nil ? "测速超时或节点不可用" : nil
            }
        } catch {
            for node in targets {
                if let index = config.nodes.firstIndex(where: { $0.id == node.id }) {
                    config.nodes[index].lastLatency = nil
                    config.nodes[index].lastError = error.localizedDescription
                }
            }
        }
        save()
        testingAll = false
        let available = targets.filter { node in config.nodes.first(where: { $0.id == node.id })?.lastLatency != nil }.count
        notice = "测速完成：\(available)/\(targets.count) 个节点可用"
    }

    func setSystemProxy(_ enabled: Bool) {
        let services = Self.networkServices()
        guard !services.isEmpty else { notice = "没有找到可配置的网络服务"; return }
        for service in services {
            _ = Self.run("/usr/sbin/networksetup", enabled ? ["-setwebproxy", service, "127.0.0.1", "\(config.proxyPort)"] : ["-setwebproxystate", service, "off"])
            _ = Self.run("/usr/sbin/networksetup", enabled ? ["-setsecurewebproxy", service, "127.0.0.1", "\(config.proxyPort)"] : ["-setsecurewebproxystate", service, "off"])
        }
        systemProxy = enabled
    }

    private func sampleTraffic() { samples.append(.init(upload: totalUpload - previousUpload, download: totalDownload - previousDownload)); previousUpload = totalUpload; previousDownload = totalDownload; if samples.count > 60 { samples.removeFirst() } }
    private func providerCacheURL(_ subscriptionID: String) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ZhilianNative/Providers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(subscriptionID + ".yaml")
    }
    private static func networkServices() -> [String] { run("/usr/sbin/networksetup", ["-listallnetworkservices"]).split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") } }
    private static func run(_ path: String, _ args: [String]) -> String { let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args; process.standardOutput = pipe; process.standardError = Pipe(); try? process.run(); process.waitUntilExit(); return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
}
