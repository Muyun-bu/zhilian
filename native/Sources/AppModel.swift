import SwiftUI
import SystemConfiguration

/// Proxy sockets can produce thousands of small read events each second. Keep
/// those counters off the main actor and publish their aggregate only once per
/// display tick, otherwise SwiftUI becomes the bottleneck during downloads.
private final class TrafficAccumulator: @unchecked Sendable {
    private struct Totals { var upload: Int64 = 0; var download: Int64 = 0 }
    private let lock = NSLock()
    private var pending: [UUID: Totals] = [:]

    func add(id: UUID, upload: Int64, download: Int64) {
        lock.lock()
        pending[id, default: .init()].upload += upload
        pending[id, default: .init()].download += download
        lock.unlock()
    }

    func drain() -> [UUID: (upload: Int64, download: Int64)] {
        lock.lock(); defer { lock.unlock() }
        let result = pending.mapValues { (upload: $0.upload, download: $0.download) }
        pending.removeAll(keepingCapacity: true)
        return result
    }
}

private struct NodeProbeResult: Sendable {
    var id: String
    var latency: Int?
    var error: String?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var config: PersistedConfig
    @Published var running = false
    @Published var systemProxy = false
    @Published var connections: [ConnectionRecord] = []
    @Published var samples: [TrafficSample] = []
    @Published var totalUpload: Int64 = 0
    @Published var totalDownload: Int64 = 0
    @Published var coreMemory: Int64 = 0
    @Published var notice: String?
    @Published var busy = false
    @Published var testingAll = false
    @Published private(set) var testingNodeIDs: Set<String> = []
    @Published private(set) var selectingNodeID: String?
    @Published private(set) var connectionTransition: ConnectionTransition?
    @Published private(set) var uninstalling = false
    let store = ConfigStore()
    private let server: ProxyServer
    private let subscriptionService = SubscriptionService()
    private let core = MihomoCore()
    private var previousUpload: Int64 = 0
    private var previousDownload: Int64 = 0
    private var timer: Timer?
    private var pollingCore = false
    private var coreSnapshotFailures = 0
    private var coreRecoveryAttempted = false
    private var networkGeneration = 0
    private var proxyOwnershipCheckTicks = 0
    private var proxyOwnershipGraceUntil = Date.distantPast
    private var lastAppliedSystemProxyPort: Int?
    private var terminationObserver: NSObjectProtocol?
    private let trafficAccumulator = TrafficAccumulator()

    var rules: [RoutingRule] { RoutingRule.builtIns + config.customRules }
    var selectedNode: ProxyNode? { config.nodes.first { $0.id == config.selectedNodeID } }
    var connectionState: ConnectionState {
        switch connectionTransition {
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        case nil: break
        }
        if running && systemProxy { return .connected }
        if running || systemProxy { return .needsRepair }
        return .disconnected
    }
    var runtimeProxyDescription: String {
        guard running else { return "未监听" }
        return config.mode != .direct ? "Mihomo · 127.0.0.1:\(core.mixedPort)" : "HTTP · 127.0.0.1:\(config.proxyPort)"
    }
    /// In rule/global modes, the system proxy points to mihomo directly. This
    /// removes the UI process from the high-throughput packet forwarding path.
    private var systemProxyPort: Int { config.mode != .direct && core.isRunning ? core.mixedPort : config.proxyPort }

    init() {
        let loadedConfig = ConfigStore().load()
        config = loadedConfig
        // Persisted flags describe whether the previous session requested a
        // complete connection. Runtime state becomes true only after macOS
        // confirms the new endpoint.
        systemProxy = false
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
        let trafficAccumulator = trafficAccumulator
        server.onTraffic = { id, up, down in
            trafficAccumulator.add(id: id, upload: up, download: down)
        }
        server.onClose = { [weak self] id, error in Task { @MainActor in
            if let index = self?.connections.firstIndex(where: { $0.id == id }) { self?.connections[index].endedAt = Date(); self?.connections[index].status = error == nil ? "完成" : "失败" }
        }}
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.updateNetworkPanel() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // The notification is already delivered on the main queue. Run
            // synchronously so the app cannot exit before restoring the proxy
            // and terminating its child core.
            MainActor.assumeIsolated { self?.shutdownForTermination() }
        }
        // A crash can leave macOS pointing at a dead local port. If the user
        // did not ask Zhilian to re-enable system proxy on this launch, restore
        // the saved pre-Zhilian settings before doing anything online.
        let shouldAutoConnect = config.autoConnectOnLaunch
        config.proxyEnabled = shouldAutoConnect
        config.systemProxyEnabled = shouldAutoConnect
        if !shouldAutoConnect, !config.systemProxyBackups.isEmpty {
            setSystemProxy(false)
        }
        if config.mode != .direct, !config.subscriptions.isEmpty {
            // Start from the saved provider first.  Waiting for an online refresh
            // here can deadlock startup when macOS still points at a former local
            // proxy port; start() immediately rebinds system proxy to this core.
            if shouldAutoConnect, let subscription = config.subscriptions.first,
               FileManager.default.fileExists(atPath: providerCacheURL(subscription.id).path) { start() }
            Task { [weak self] in
                guard let self else { return }
                for subscription in self.config.subscriptions { await self.refreshSubscription(subscription.id) }
                if self.config.proxyEnabled && self.config.systemProxyEnabled && !self.running { self.start() }
            }
        } else if shouldAutoConnect {
            start()
        }
    }

    func start() {
        guard !busy, !testingAll, testingNodeIDs.isEmpty, selectingNodeID == nil else {
            notice = "请等待当前操作完成后再启动代理"
            return
        }
        if connectionTransition == nil, config.systemProxyEnabled {
            connectionTransition = .connecting
        }
        if config.mode != .direct, let subscription = config.subscriptions.first {
            let cache = providerCacheURL(subscription.id)
            guard FileManager.default.fileExists(atPath: cache.path) else {
                notice = "正在更新订阅，完成后自动启动代理"
                config.proxyEnabled = true
                save()
                if !busy {
                    Task { [weak self] in
                        guard let self else { return }
                        await self.refreshSubscription(subscription.id)
                        if FileManager.default.fileExists(atPath: cache.path),
                           self.config.proxyEnabled, !self.running,
                           self.config.subscriptions.first?.lastError == nil {
                            self.start()
                        } else if !FileManager.default.fileExists(atPath: cache.path) {
                            self.config.proxyEnabled = false
                            self.config.systemProxyEnabled = false
                            self.connectionTransition = nil
                            self.save()
                        }
                    }
                }
                return
            }
            do { try core.start(providerFile: cache, selectedNode: selectedNode?.name, mode: config.mode) }
            catch { failSafeAfterCoreFailure("代理核心启动失败：\(error.localizedDescription)"); return }
        } else if config.mode != .direct {
            config.proxyEnabled = false
            config.systemProxyEnabled = false
            connectionTransition = nil
            save()
            notice = "请先添加并更新订阅，再启动代理"
            return
        }
        // Mihomo owns the HTTP/SOCKS endpoint used by macOS system proxy.  The
        // Swift proxy remains available only in direct mode for the detailed
        // inspection panel, so normal proxy traffic never wakes this process.
        if config.mode != .direct {
            running = true
            config.proxyEnabled = true
            resetNetworkPanel()
            save()
            completeConnectionActivation()
            return
        }
        let requestedPort = config.proxyPort
        guard (1...65_535).contains(requestedPort) else {
            running = false; config.proxyEnabled = false; config.systemProxyEnabled = false
            connectionTransition = nil; notice = "监听端口必须在 1 到 65535 之间"; save(); return
        }
        let lastPort = min(65_535, requestedPort + 20)
        for port in requestedPort...lastPort {
            do {
                try server.start(port: port)
                config.proxyPort = port; running = true; config.proxyEnabled = true; save()
                completeConnectionActivation()
                if port != requestedPort { notice = "端口 \(requestedPort) 被占用，已自动切换到 \(port)" }
                return
            } catch { continue }
        }
        running = false; config.proxyEnabled = false; config.systemProxyEnabled = false
        connectionTransition = nil; notice = "无法找到可用的本地代理端口"; save()
    }

    func connect() {
        guard connectionTransition == nil else { return }
        guard !busy, !testingAll, testingNodeIDs.isEmpty, selectingNodeID == nil else {
            notice = "请等待当前操作完成后再连接网络"
            return
        }
        connectionTransition = .connecting
        config.proxyEnabled = true
        config.systemProxyEnabled = true
        save()
        if running {
            completeConnectionActivation()
        } else {
            start()
        }
    }

    /// Restores the previous macOS proxy before stopping the local endpoint.
    /// If an owned proxy cannot be restored, keep the core alive so the Mac is
    /// not left pointing at a dead port.
    @discardableResult
    func stop() -> Bool {
        connectionTransition = .disconnecting
        let expectedPort = lastAppliedSystemProxyPort ?? (running ? systemProxyPort : nil)
        if systemProxy || !config.systemProxyBackups.isEmpty { setSystemProxy(false) }
        if let expectedPort, Self.anyServicePointsToLocalPort(expectedPort) {
            config.proxyEnabled = true
            config.systemProxyEnabled = false
            connectionTransition = nil
            save()
            notice = "系统网络设置尚未完全恢复；为避免断网，代理核心将继续运行，请再次点击断开重试"
            return false
        }
        server.stop()
        core.stopAndWait()
        running = false
        systemProxy = false
        config.proxyEnabled = false
        config.systemProxyEnabled = false
        connectionTransition = nil
        resetNetworkPanel()
        save()
        return true
    }

    func toggleConnection() {
        guard connectionTransition == nil else { return }
        switch connectionState {
        case .disconnected: connect()
        case .connected, .needsRepair: _ = stop()
        case .connecting, .disconnecting: break
        }
    }

    func setAutoConnectOnLaunch(_ enabled: Bool) {
        config.autoConnectOnLaunch = enabled
        save()
    }

    /// Finder only moves an app bundle to Trash; it cannot safely restore the
    /// proxy or remove the app's private data. This explicit flow does both,
    /// then removes only Zhilian's Launchpad entry and exits without saving a
    /// fresh config file during the termination notification.
    func uninstallApplication() {
        guard !uninstalling else { return }
        guard !busy, !testingAll, testingNodeIDs.isEmpty, selectingNodeID == nil else {
            notice = "请等待当前操作完成后再卸载智连"
            return
        }
        guard stop() else { return }
        uninstalling = true
        timer?.invalidate()
        do {
            let result = try UninstallService.perform(runningApplicationURL: Bundle.main.bundleURL)
            if !result.cleanupFailures.isEmpty {
                let alert = NSAlert()
                alert.messageText = "智连已移入废纸篓"
                alert.informativeText = "以下数据未能删除：\n" + result.cleanupFailures.joined(separator: "\n")
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
            NSApplication.shared.terminate(nil)
        } catch {
            uninstalling = false
            connectionTransition = nil
            notice = error.localizedDescription
        }
    }

    private func completeConnectionActivation() {
        guard running else {
            connectionTransition = nil
            return
        }
        guard config.systemProxyEnabled else {
            connectionTransition = nil
            return
        }
        setSystemProxy(true)
        guard systemProxy else {
            let failure = notice ?? "系统代理未能启用"
            connectionTransition = nil
            if !Self.anyServicePointsToLocalPort(systemProxyPort) {
                server.stop()
                core.stopAndWait()
                running = false
                config.proxyEnabled = false
                config.systemProxyEnabled = false
                resetNetworkPanel()
                save()
                notice = "连接失败，系统网络已回滚：\(failure)"
            } else {
                config.proxyEnabled = true
                save()
                notice = "系统网络未完全应用，代理核心保持运行以避免断网：\(failure)"
            }
            return
        }
        connectionTransition = nil
    }

    func save() { store.save(config) }

    func addSubscription(name: String, url: String) async {
        guard config.subscriptions.isEmpty else {
            notice = "当前版本仅支持一个活动订阅，请先删除现有订阅"
            return
        }
        let profile = SubscriptionProfile(id: UUID().uuidString, name: name.isEmpty ? "我的订阅" : name, url: url, updatedAt: nil, nodeIDs: [], lastError: nil)
        config.subscriptions.append(profile); save(); await refreshSubscription(profile.id)
    }
    func refreshSubscription(_ id: String) async {
        guard !busy else { return }
        guard !testingAll, testingNodeIDs.isEmpty, selectingNodeID == nil else { notice = "请等待节点操作完成后再更新订阅"; return }
        guard let profile = config.subscriptions.first(where: { $0.id == id }) else { return }
        let cache = providerCacheURL(id)
        let oldDocument = try? Data(contentsOf: cache)
        let oldNodes = config.nodes.filter { $0.sourceID == id }
        let oldSelectedNodeID = config.selectedNodeID
        busy = true
        defer { busy = false }
        var changed = false
        do {
            let result = try await subscriptionService.fetchResult(url: profile.url, sourceID: id)
            var nodes = result.nodes
            let priorNodeState = Dictionary(oldNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in nodes.indices {
                nodes[index].lastLatency = priorNodeState[nodes[index].id]?.lastLatency
                nodes[index].lastError = priorNodeState[nodes[index].id]?.lastError
            }
            guard config.subscriptions.contains(where: { $0.id == id }) else { return }
            changed = oldDocument != result.document
            if !core.isRunning {
                try await validateProviderDocument(result.document, subscriptionID: id)
            }
            try result.document.write(to: cache, options: .atomic)
            guard let index = config.subscriptions.firstIndex(where: { $0.id == id }) else { return }
            config.nodes.removeAll { $0.sourceID == id }; config.nodes.append(contentsOf: nodes)
            config.subscriptions[index].nodeIDs = nodes.map(\.id); config.subscriptions[index].updatedAt = Date(); config.subscriptions[index].lastError = nil
            if !nodes.contains(where: { $0.id == config.selectedNodeID && $0.isSelectableProxy }) {
                config.selectedNodeID = nodes.first(where: \.isSelectableProxy)?.id
            }
            notice = "已更新 \(nodes.count) 个节点"
        } catch {
            if let index = config.subscriptions.firstIndex(where: { $0.id == id }) { config.subscriptions[index].lastError = error.localizedDescription }
            notice = error.localizedDescription
        }
        save()
        if changed, running, config.mode != .direct, config.subscriptions.first?.id == id, let subscription = config.subscriptions.first {
            do {
                try core.start(providerFile: providerCacheURL(subscription.id), selectedNode: selectedNode?.name, mode: config.mode, forceReload: true)
                resetNetworkPanel()
                if systemProxy, !refreshSystemProxyEndpoint() {
                    failSafeAfterCoreFailure("订阅已更新，但系统代理端口更新失败")
                }
            }
            catch {
                let rejectedReason = error.localizedDescription
                guard let oldDocument else {
                    failSafeAfterCoreFailure("核心重载失败：\(rejectedReason)")
                    return
                }
                do {
                    try oldDocument.write(to: cache, options: .atomic)
                    config.nodes.removeAll { $0.sourceID == id }
                    config.nodes.append(contentsOf: oldNodes)
                    if let index = config.subscriptions.firstIndex(where: { $0.id == id }) {
                        config.subscriptions[index] = profile
                        config.subscriptions[index].lastError = "新订阅无法加载：\(rejectedReason)"
                    }
                    config.selectedNodeID = oldSelectedNodeID
                    let oldSelectedName = oldNodes.first { $0.id == oldSelectedNodeID }?.name
                    try core.start(providerFile: cache, selectedNode: oldSelectedName, mode: config.mode, forceReload: true)
                    running = true
                    resetNetworkPanel()
                    if systemProxy, !refreshSystemProxyEndpoint() {
                        throw TunnelError.connect("恢复旧订阅后，系统代理端口更新失败")
                    }
                    save()
                    notice = "新订阅无法加载，已恢复上一次可用配置：\(rejectedReason)"
                } catch {
                    failSafeAfterCoreFailure("新订阅与旧配置均无法启动：\(error.localizedDescription)")
                }
            }
        }
    }
    func removeSubscription(_ id: String) {
        guard !busy, !testingAll, testingNodeIDs.isEmpty, selectingNodeID == nil else { notice = "请等待当前操作完成后再删除订阅"; return }
        let removingActive = config.subscriptions.first?.id == id && running && config.mode != .direct
        if removingActive { stop() }
        config.nodes.removeAll { $0.sourceID == id }
        config.subscriptions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: providerCacheURL(id))
        if !config.nodes.contains(where: { $0.id == config.selectedNodeID && $0.isSelectableProxy }) { config.selectedNodeID = config.nodes.first(where: \.isSelectableProxy)?.id }
        save()
    }

    func testNode(_ id: String) async {
        guard !busy, !testingAll, testingNodeIDs.isEmpty, selectingNodeID == nil else { return }
        guard let node = config.nodes.first(where: { $0.id == id }) else { return }
        guard node.isSelectableProxy else { return }
        testingNodeIDs.insert(id)
        defer { testingNodeIDs.remove(id) }
        let host = node.host
        let port = node.port
        let timeout = max(1, config.latencyTimeoutMilliseconds / 1_000)
        let measurement = await Task.detached(priority: .utility) {
            NodeLatencyProbe.measure(host: host, port: port, attempts: 3, timeoutSeconds: timeout)
        }.value
        guard let index = config.nodes.firstIndex(where: { $0.id == id }) else { return }
        config.nodes[index].lastLatency = measurement.milliseconds
        config.nodes[index].lastError = measurement.error
        save()
    }

    func selectNode(_ id: String) async {
        guard !busy, !testingAll, testingNodeIDs.isEmpty, selectingNodeID == nil else { notice = "请等待当前操作完成后再切换节点"; return }
        guard let node = config.nodes.first(where: { $0.id == id }), node.isSelectableProxy else { return }
        guard config.subscriptions.first?.id == node.sourceID else { notice = "该节点不属于当前活动订阅"; return }
        guard config.selectedNodeID != id else { return }
        selectingNodeID = id
        defer { selectingNodeID = nil }
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
        guard !busy, testingNodeIDs.isEmpty, selectingNodeID == nil else { notice = "请等待当前操作完成"; return }
        guard let subscription = config.subscriptions.first else { notice = "请先添加并更新订阅"; return }
        testingAll = true
        defer { testingAll = false }
        let requestedIDs = ids.map(Set.init)
        let targets = config.nodes.filter { $0.sourceID == subscription.id && $0.isSelectableProxy && (requestedIDs?.contains($0.id) ?? true) }
        guard !targets.isEmpty else { notice = "没有可测速的节点"; return }
        let timeout = max(1, config.latencyTimeoutMilliseconds / 1_000)
        let probeTargets = targets.map { (id: $0.id, host: $0.host, port: $0.port) }
        for batchStart in stride(from: 0, to: probeTargets.count, by: 4) {
            let batchEnd = min(batchStart + 4, probeTargets.count)
            let batch = Array(probeTargets[batchStart..<batchEnd])
            let results = await withTaskGroup(of: NodeProbeResult.self, returning: [NodeProbeResult].self) { group in
                for target in batch {
                    group.addTask {
                        let measurement = NodeLatencyProbe.measure(host: target.host, port: target.port, attempts: 3, timeoutSeconds: timeout)
                        return .init(id: target.id, latency: measurement.milliseconds, error: measurement.error)
                    }
                }
                var values: [NodeProbeResult] = []
                for await result in group { values.append(result) }
                return values
            }
            for result in results {
                guard let index = config.nodes.firstIndex(where: { $0.id == result.id }) else { continue }
                config.nodes[index].lastLatency = result.latency
                config.nodes[index].lastError = result.error
            }
            save()
        }
        let available = targets.filter { node in config.nodes.first(where: { $0.id == node.id })?.lastLatency != nil }.count
        notice = "节点延迟测试完成：\(available)/\(targets.count) 个服务器可连接"
    }

    func setSystemProxy(_ enabled: Bool) {
        if enabled && !running {
            let subscriptionCacheMissing = config.mode != .direct && config.subscriptions.first.map {
                !FileManager.default.fileExists(atPath: providerCacheURL($0.id).path)
            } == true
            config.systemProxyEnabled = true
            config.proxyEnabled = true
            save()
            start()
            guard running else {
                systemProxy = false
                if !subscriptionCacheMissing {
                    config.systemProxyEnabled = false
                    config.proxyEnabled = false
                    save()
                }
                return
            }
            // start() completes the unified activation and applies the system
            // proxy. Returning here prevents a second backup/apply pass.
            return
        }
        let services = Self.networkServices()
        guard !services.isEmpty else { notice = "没有找到可配置的网络服务"; return }
        if !enabled, config.systemProxyBackups.isEmpty {
            // We have no evidence that Zhilian changed macOS. Never turn off a
            // proxy owned by another app merely because the UI toggle is false.
            systemProxy = false
            config.systemProxyEnabled = false
            save()
            return
        }
        var failures: [String] = []
        if enabled {
            // Network services can disappear after a dock, VPN, or interface
            // change. A backup for a service that no longer exists must not
            // prevent the remaining active services from connecting.
            config.systemProxyBackups.removeAll { !services.contains($0.service) }
            let hadBackups = !config.systemProxyBackups.isEmpty
            var activationAttempted = false
            // Preserve the original macOS proxy exactly once.  Reapplying after
            // a core restart must not overwrite it with Zhilian's old port.
            if config.systemProxyBackups.isEmpty {
                config.systemProxyBackups = services.compactMap { service in
                    guard let web = Self.proxyEndpoint(service: service, secure: false),
                          let secure = Self.proxyEndpoint(service: service, secure: true),
                          let socks = Self.socksProxyEndpoint(service: service) else {
                        failures.append(service)
                        return nil
                    }
                    return .init(service: service, web: web, secureWeb: secure, socks: socks)
                }
            } else {
                // Older versions never changed SOCKS. Capture its still-original
                // value before the first upgraded activation.
                for index in config.systemProxyBackups.indices where config.systemProxyBackups[index].socks == nil {
                    guard let socks = Self.socksProxyEndpoint(service: config.systemProxyBackups[index].service) else {
                        failures.append(config.systemProxyBackups[index].service)
                        continue
                    }
                    config.systemProxyBackups[index].socks = socks
                }
                // A network service may have been added while Zhilian was
                // running. Back it up before changing it as well.
                let knownServices = Set(config.systemProxyBackups.map(\.service))
                for service in services where !knownServices.contains(service) {
                    guard let web = Self.proxyEndpoint(service: service, secure: false),
                          let secure = Self.proxyEndpoint(service: service, secure: true),
                          let socks = Self.socksProxyEndpoint(service: service) else {
                        failures.append(service)
                        continue
                    }
                    config.systemProxyBackups.append(.init(service: service, web: web, secureWeb: secure, socks: socks))
                }
            }
            if failures.isEmpty {
                activationAttempted = true
                failures.append(contentsOf: applySystemProxy(services: services))
            }
            if !failures.isEmpty, activationAttempted {
                // Roll back partial activation so one failed network service
                // cannot leave macOS in a half-proxied state.
                let backups = Dictionary(config.systemProxyBackups.map { ($0.service, $0) }, uniquingKeysWith: { first, _ in first })
                var rollbackFailed = false
                for service in services {
                    let backup = backups[service]
                    let web = Self.restoreProxy(service: service, endpoint: backup?.web, secure: false)
                    let secure = Self.restoreProxy(service: service, endpoint: backup?.secureWeb, secure: true)
                    let socks = backup?.socks.map { Self.restoreSocksProxy(service: service, endpoint: $0) } ?? true
                    rollbackFailed = rollbackFailed || !web || !secure || !socks
                }
                if !rollbackFailed { config.systemProxyBackups = [] }
            } else if !failures.isEmpty, !hadBackups {
                // Nothing was changed, so discard an incomplete fresh backup
                // instead of using it during a later restore.
                config.systemProxyBackups = []
            }
        } else {
            if running || lastAppliedSystemProxyPort != nil {
                // During a live disconnect, only restore entries that still
                // point at Zhilian. Another proxy app may have taken ownership
                // since activation and must not be overwritten.
                let expectedPort = lastAppliedSystemProxyPort ?? systemProxyPort
                let unresolved = relinquishSystemProxy(expectedPort: expectedPort)
                failures.append(contentsOf: unresolved.map(\.service))
                config.systemProxyBackups = unresolved
            } else {
                // Crash recovery has no live core/port ownership marker. Use
                // the saved snapshot to restore every still-existing service.
                let backups = Dictionary(config.systemProxyBackups.map { ($0.service, $0) }, uniquingKeysWith: { first, _ in first })
                var unresolvedBackups = config.systemProxyBackups.filter { !services.contains($0.service) }
                for (service, backup) in backups {
                    guard services.contains(service) else { continue }
                    let webRestored = Self.restoreProxy(service: service, endpoint: backup.web, secure: false)
                    let secureRestored = Self.restoreProxy(service: service, endpoint: backup.secureWeb, secure: true)
                    let socksRestored = backup.socks.map { Self.restoreSocksProxy(service: service, endpoint: $0) } ?? true
                    if !webRestored || !secureRestored || !socksRestored {
                        failures.append(service)
                        unresolvedBackups.append(backup)
                    }
                }
                config.systemProxyBackups = unresolvedBackups
            }
        }
        systemProxy = enabled && failures.isEmpty
        config.systemProxyEnabled = systemProxy
        if systemProxy {
            lastAppliedSystemProxyPort = systemProxyPort
            proxyOwnershipGraceUntil = Date().addingTimeInterval(3)
        } else {
            lastAppliedSystemProxyPort = nil
        }
        save()
        if !failures.isEmpty { notice = "系统代理未能应用到：\(failures.sorted().joined(separator: "、"))" }
    }

    func changeMode(_ mode: ProxyMode) {
        guard config.mode != mode else { return }
        guard !busy, !testingAll, testingNodeIDs.isEmpty, selectingNodeID == nil, connectionTransition == nil else { notice = "请等待当前操作完成后再切换模式"; return }
        let previousMode = config.mode
        config.mode = mode
        save()
        guard running else { return }
        if mode == .direct {
            core.stopAndWait()
            server.stop()
            running = false
            resetNetworkPanel()
            start()
        } else {
            server.stop()
            guard let subscription = config.subscriptions.first else {
                stop()
                notice = "请先添加并更新订阅，再切换代理模式"
                return
            }
            do { try core.start(providerFile: providerCacheURL(subscription.id), selectedNode: selectedNode?.name, mode: mode, forceReload: true) }
            catch {
                let switchError = error.localizedDescription
                config.mode = previousMode
                if previousMode == .direct {
                    running = false
                    start()
                    notice = running ? "模式切换失败，已恢复直连模式：\(switchError)" : "模式切换失败且直连模式未能恢复：\(switchError)"
                } else {
                    do {
                        try core.start(providerFile: providerCacheURL(subscription.id), selectedNode: selectedNode?.name, mode: previousMode, forceReload: true)
                        running = true
                        if systemProxy, !refreshSystemProxyEndpoint() {
                            throw TunnelError.connect("恢复原模式后，系统代理端口更新失败")
                        }
                        save()
                        notice = "模式切换失败，已恢复原模式：\(switchError)"
                    } catch {
                        failSafeAfterCoreFailure("模式切换及恢复均失败：\(error.localizedDescription)")
                    }
                }
                return
            }
            resetNetworkPanel()
            if systemProxy, !refreshSystemProxyEndpoint() {
                failSafeAfterCoreFailure("模式已切换，但系统代理端口更新失败")
            }
        }
    }

    /// Rebind an already-enabled macOS proxy after mihomo receives a new
    /// per-process mixed-port.  This avoids a running UI with a stale system
    /// proxy pointing at a core that has already exited.
    @discardableResult
    private func refreshSystemProxyEndpoint() -> Bool {
        guard running else { return false }
        setSystemProxy(true)
        return systemProxy
    }

    private func applySystemProxy(services: [String]) -> [String] {
        var failures: [String] = []
        for service in services {
            let web = Self.run("/usr/sbin/networksetup", ["-setwebproxy", service, "127.0.0.1", "\(systemProxyPort)"])
            let secure = Self.run("/usr/sbin/networksetup", ["-setsecurewebproxy", service, "127.0.0.1", "\(systemProxyPort)"])
            let socks: (success: Bool, output: String)
            if config.mode == .direct {
                socks = Self.run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"])
            } else {
                socks = Self.run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, "127.0.0.1", "\(systemProxyPort)"])
            }
            let expected = systemProxyPort
            let appliedWeb = Self.proxyEndpoint(service: service, secure: false)
            let appliedSecure = Self.proxyEndpoint(service: service, secure: true)
            let appliedSocks = Self.socksProxyEndpoint(service: service)
            let verified = appliedWeb?.enabled == true && appliedWeb?.server == "127.0.0.1" && appliedWeb?.port == expected
                && appliedSecure?.enabled == true && appliedSecure?.server == "127.0.0.1" && appliedSecure?.port == expected
            let socksVerified: Bool
            if config.mode == .direct {
                socksVerified = appliedSocks?.enabled == false
            } else {
                socksVerified = appliedSocks?.enabled == true && appliedSocks?.server == "127.0.0.1" && appliedSocks?.port == expected
            }
            if !web.success || !secure.success || !socks.success || !verified || !socksVerified { failures.append(service) }
        }
        return failures
    }

    private static func anyServicePointsToLocalPort(_ expectedPort: Int) -> Bool {
        func owned(_ endpoint: SystemProxyEndpoint?) -> Bool {
            endpoint?.enabled == true && endpoint?.server == "127.0.0.1" && endpoint?.port == expectedPort
        }
        return networkServices().contains { service in
            owned(proxyEndpoint(service: service, secure: false))
                || owned(proxyEndpoint(service: service, secure: true))
                || owned(socksProxyEndpoint(service: service))
        }
    }

    /// Last-resort shutdown protection. This never installs another endpoint;
    /// it only disables protocol entries that still point at this exact core.
    private static func disableOwnedProxyEndpoints(expectedPort: Int) {
        func owned(_ endpoint: SystemProxyEndpoint?) -> Bool {
            endpoint?.enabled == true && endpoint?.server == "127.0.0.1" && endpoint?.port == expectedPort
        }
        for service in networkServices() {
            if owned(proxyEndpoint(service: service, secure: false)) {
                _ = run("/usr/sbin/networksetup", ["-setwebproxystate", service, "off"])
            }
            if owned(proxyEndpoint(service: service, secure: true)) {
                _ = run("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "off"])
            }
            if owned(socksProxyEndpoint(service: service)) {
                _ = run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"])
            }
        }
    }

    private func updateNetworkPanel() async {
        guard running else { return }
        if systemProxy {
            proxyOwnershipCheckTicks += 1
            if proxyOwnershipCheckTicks >= 5, Date() >= proxyOwnershipGraceUntil {
                proxyOwnershipCheckTicks = 0
                if let expectedPort = lastAppliedSystemProxyPort,
                   !effectiveSystemProxyMatches(expectedPort: expectedPort) {
                    // Another app or the user changed macOS after Zhilian took
                    // ownership. Restore only protocol entries that still point
                    // at our old port, without overwriting the newer choice.
                    let unresolved = relinquishSystemProxy(expectedPort: expectedPort)
                    systemProxy = false
                    lastAppliedSystemProxyPort = nil
                    config.systemProxyEnabled = false
                    config.systemProxyBackups = unresolved
                    save()
                    notice = "系统代理已被其他设置接管；智连核心仍在运行，但不会覆盖新的代理配置"
                }
            }
        } else {
            proxyOwnershipCheckTicks = 0
        }
        if config.mode != .direct {
            guard core.isRunning else {
                coreSnapshotFailures += 1
                if coreSnapshotFailures >= 3 {
                    if !coreRecoveryAttempted {
                        coreRecoveryAttempted = true
                        if recoverCore() { return }
                    }
                    failSafeAfterCoreFailure("代理核心意外停止，系统代理已恢复")
                }
                return
            }
            guard !pollingCore else { return }
            pollingCore = true
            defer { pollingCore = false }
            let generation = networkGeneration
            do {
                let snapshot = try await core.connectionSnapshot()
                guard running, config.mode != .direct, core.isRunning, generation == networkGeneration else { return }
                apply(snapshot)
                coreSnapshotFailures = 0
                coreRecoveryAttempted = false
            } catch {
                coreSnapshotFailures += 1
                // A request can race with a subscription reload. Only restart
                // after repeated failures, and only once for each outage.
                if coreSnapshotFailures >= 5 {
                    if !coreRecoveryAttempted {
                        coreRecoveryAttempted = true
                        if recoverCore() { return }
                    }
                    failSafeAfterCoreFailure("代理核心或连接面板无响应：\(error.localizedDescription)")
                }
            }
            return
        }
        sampleLocalProxyTraffic()
    }

    private func apply(_ snapshot: CoreConnectionSnapshot) {
        let uploadDelta = max(0, snapshot.uploadTotal - totalUpload)
        let downloadDelta = max(0, snapshot.downloadTotal - totalDownload)
        totalUpload = snapshot.uploadTotal
        totalDownload = snapshot.downloadTotal
        coreMemory = snapshot.memory
        let activeIDs = Set(snapshot.connections.map(\.id))
        var history = connections.filter { !activeIDs.contains($0.id) }
        for index in history.indices where history[index].endedAt == nil {
            history[index].endedAt = Date()
            history[index].status = "完成"
        }
        let combined = snapshot.connections + history
        connections = Array(combined.sorted { $0.startedAt > $1.startedAt }.prefix(300))
        samples.append(.init(upload: uploadDelta, download: downloadDelta))
        if samples.count > 60 { samples.removeFirst() }
        previousUpload = totalUpload
        previousDownload = totalDownload
    }

    private func sampleLocalProxyTraffic() {
        // Direct mode still uses the Swift inspection proxy.
        for (id, delta) in trafficAccumulator.drain() {
            totalUpload += delta.upload
            totalDownload += delta.download
            if let index = connections.firstIndex(where: { $0.id == id }) {
                connections[index].uploaded += delta.upload
                connections[index].downloaded += delta.download
            }
        }
        samples.append(.init(upload: totalUpload - previousUpload, download: totalDownload - previousDownload))
        previousUpload = totalUpload
        previousDownload = totalDownload
        if samples.count > 60 { samples.removeFirst() }
    }

    private func resetNetworkPanel() {
        _ = trafficAccumulator.drain()
        connections = []
        samples = []
        totalUpload = 0
        totalDownload = 0
        coreMemory = 0
        previousUpload = 0
        previousDownload = 0
        coreSnapshotFailures = 0
        coreRecoveryAttempted = false
        networkGeneration &+= 1
    }

    private func effectiveSystemProxyMatches(expectedPort: Int) -> Bool {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        func enabled(_ key: CFString) -> Bool {
            (proxies[key as String] as? NSNumber)?.boolValue == true
        }
        func host(_ key: CFString) -> String {
            proxies[key as String] as? String ?? ""
        }
        func port(_ key: CFString) -> Int {
            (proxies[key as String] as? NSNumber)?.intValue ?? 0
        }
        let webMatches = enabled(kSCPropNetProxiesHTTPEnable)
            && host(kSCPropNetProxiesHTTPProxy) == "127.0.0.1"
            && port(kSCPropNetProxiesHTTPPort) == expectedPort
        let secureMatches = enabled(kSCPropNetProxiesHTTPSEnable)
            && host(kSCPropNetProxiesHTTPSProxy) == "127.0.0.1"
            && port(kSCPropNetProxiesHTTPSPort) == expectedPort
        let socksMatches: Bool
        if config.mode == .direct {
            socksMatches = !enabled(kSCPropNetProxiesSOCKSEnable)
        } else {
            socksMatches = enabled(kSCPropNetProxiesSOCKSEnable)
                && host(kSCPropNetProxiesSOCKSProxy) == "127.0.0.1"
                && port(kSCPropNetProxiesSOCKSPort) == expectedPort
        }
        return webMatches && secureMatches && socksMatches
    }

    private func relinquishSystemProxy(expectedPort: Int) -> [SystemProxyBackup] {
        let services = Self.networkServices()
        var unresolved: [SystemProxyBackup] = []
        func owned(_ endpoint: SystemProxyEndpoint?) -> Bool {
            endpoint?.enabled == true && endpoint?.server == "127.0.0.1" && endpoint?.port == expectedPort
        }
        for backup in config.systemProxyBackups {
            guard services.contains(backup.service),
                  let web = Self.proxyEndpoint(service: backup.service, secure: false),
                  let secure = Self.proxyEndpoint(service: backup.service, secure: true),
                  let socks = Self.socksProxyEndpoint(service: backup.service) else {
                unresolved.append(backup)
                continue
            }
            var restored = true
            if owned(web) {
                restored = Self.restoreProxy(service: backup.service, endpoint: backup.web, secure: false) && restored
            }
            if owned(secure) {
                restored = Self.restoreProxy(service: backup.service, endpoint: backup.secureWeb, secure: true) && restored
            }
            let socksOwned = config.mode == .direct ? !socks.enabled : owned(socks)
            if socksOwned, let originalSocks = backup.socks {
                restored = Self.restoreSocksProxy(service: backup.service, endpoint: originalSocks) && restored
            }
            if !restored { unresolved.append(backup) }
        }
        return unresolved
    }

    private func recoverCore() -> Bool {
        guard config.mode != .direct,
              let subscription = config.subscriptions.first,
              FileManager.default.fileExists(atPath: providerCacheURL(subscription.id).path) else { return false }
        do {
            try core.start(providerFile: providerCacheURL(subscription.id), selectedNode: selectedNode?.name,
                           mode: config.mode, forceReload: true)
            resetNetworkPanel()
            coreRecoveryAttempted = true
            if systemProxy {
                guard refreshSystemProxyEndpoint(), systemProxy else { return false }
            }
            notice = "代理核心已自动恢复"
            return true
        } catch {
            notice = "代理核心自动恢复失败：\(error.localizedDescription)"
            return false
        }
    }

    private func failSafeAfterCoreFailure(_ message: String) {
        let expectedPort = lastAppliedSystemProxyPort ?? (running ? systemProxyPort : nil)
        if systemProxy || !config.systemProxyBackups.isEmpty { setSystemProxy(false) }
        if let expectedPort, Self.anyServicePointsToLocalPort(expectedPort) {
            Self.disableOwnedProxyEndpoints(expectedPort: expectedPort)
        }
        server.stop()
        core.stopAndWait()
        running = false
        systemProxy = false
        config.proxyEnabled = false
        config.systemProxyEnabled = false
        connectionTransition = nil
        resetNetworkPanel()
        save()
        notice = message
    }

    /// AppKit calls this on Quit.  Unlike the visible Stop button, process
    /// cleanup must not silently change the user's "start on launch" choice.
    private func shutdownForTermination() {
        if uninstalling {
            timer?.invalidate()
            server.stop()
            core.stopAndWait()
            return
        }
        let reconnectOnNextLaunch = config.autoConnectOnLaunch
        let expectedPort = lastAppliedSystemProxyPort ?? (running ? systemProxyPort : nil)
        if systemProxy || !config.systemProxyBackups.isEmpty { setSystemProxy(false) }
        if let expectedPort, Self.anyServicePointsToLocalPort(expectedPort) {
            Self.disableOwnedProxyEndpoints(expectedPort: expectedPort)
        }
        server.stop()
        core.stopAndWait()
        running = false
        systemProxy = false
        config.proxyEnabled = reconnectOnNextLaunch
        config.systemProxyEnabled = reconnectOnNextLaunch
        connectionTransition = nil
        save()
    }
    private func providerCacheURL(_ subscriptionID: String) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ZhilianNative/Providers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(subscriptionID + ".yaml")
    }
    private func validateProviderDocument(_ document: Data, subscriptionID: String) async throws {
        let cache = providerCacheURL(subscriptionID)
        let candidate = cache.deletingLastPathComponent().appendingPathComponent(".candidate-\(UUID().uuidString).yaml")
        try document.write(to: candidate, options: .atomic)
        defer {
            core.stopAndWait()
            try? FileManager.default.removeItem(at: candidate)
        }
        try core.start(providerFile: candidate, selectedNode: nil, mode: config.mode == .direct ? .rule : config.mode)
        try await core.validateProviderLoaded()
    }
    private static func networkServices() -> [String] { run("/usr/sbin/networksetup", ["-listallnetworkservices"]).output.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") } }
    private static func proxyEndpoint(service: String, secure: Bool) -> SystemProxyEndpoint? {
        let result = run("/usr/sbin/networksetup", [secure ? "-getsecurewebproxy" : "-getwebproxy", service])
        guard result.success else { return nil }
        var values: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        guard let state = values["Enabled"] else { return nil }
        return .init(enabled: state.caseInsensitiveCompare("Yes") == .orderedSame, server: values["Server"] ?? "", port: Int(values["Port"] ?? "") ?? 0)
    }
    private static func socksProxyEndpoint(service: String) -> SystemProxyEndpoint? {
        let result = run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])
        guard result.success else { return nil }
        var values: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        guard let state = values["Enabled"] else { return nil }
        return .init(enabled: state.caseInsensitiveCompare("Yes") == .orderedSame,
                     server: values["Server"] ?? "", port: Int(values["Port"] ?? "") ?? 0)
    }
    private static func restoreProxy(service: String, endpoint: SystemProxyEndpoint?, secure: Bool) -> Bool {
        let stateFlag = secure ? "-setsecurewebproxystate" : "-setwebproxystate"
        let setFlag = secure ? "-setsecurewebproxy" : "-setwebproxy"
        guard let endpoint else {
            return run("/usr/sbin/networksetup", [stateFlag, service, "off"]).success
        }
        var success = true
        if !endpoint.server.isEmpty, endpoint.port > 0 {
            success = run("/usr/sbin/networksetup", [setFlag, service, endpoint.server, "\(endpoint.port)"]).success
        }
        let state = run("/usr/sbin/networksetup", [stateFlag, service, endpoint.enabled ? "on" : "off"]).success
        return success && state
    }
    private static func restoreSocksProxy(service: String, endpoint: SystemProxyEndpoint) -> Bool {
        var success = true
        if !endpoint.server.isEmpty, endpoint.port > 0 {
            success = run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, endpoint.server, "\(endpoint.port)"]).success
        }
        let state = run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, endpoint.enabled ? "on" : "off"]).success
        return success && state
    }
    private static func run(_ path: String, _ args: [String]) -> (success: Bool, output: String) {
        let process = Process(); let output = Pipe(); let error = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = args; process.standardOutput = output; process.standardError = error
        do { try process.run() } catch { return (false, error.localizedDescription) }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile() + error.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }
}
