import SwiftUI

private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
}

struct Header: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(value)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.quaternary)
        }
    }
}

private struct ModeControl: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ProxyMode.allCases) { mode in
                Button {
                    model.changeMode(mode)
                } label: {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.config.mode == mode ? Color.primary : Color.secondary)
                        .frame(minWidth: 58, minHeight: 30)
                        .background {
                            if model.config.mode == mode {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.background)
                                    .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换到\(mode.title)模式")
            }
        }
        .padding(3)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.quaternary)
        }
        .disabled(model.connectionTransition != nil || model.busy || model.testingAll || !model.testingNodeIDs.isEmpty || model.selectingNodeID != nil)
    }
}

private struct ConnectionPowerButton: View {
    @EnvironmentObject private var model: AppModel

    private var presentation: (title: String, icon: String, color: Color) {
        switch model.connectionState {
        case .disconnected: ("连接网络", "power", .accentColor)
        case .connecting: ("连接中…", "arrow.triangle.2.circlepath", .accentColor)
        case .connected: ("断开连接", "power.circle.fill", .red)
        case .disconnecting: ("正在恢复网络…", "arrow.uturn.backward.circle", .orange)
        case .needsRepair: ("安全断开", "exclamationmark.shield.fill", .orange)
        }
    }

    private var transitioning: Bool {
        model.connectionTransition != nil
    }

    var body: some View {
        Button {
            model.toggleConnection()
        } label: {
            HStack(spacing: 10) {
                if transitioning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 22, weight: .semibold))
                }
                Text(presentation.title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(minWidth: 166, minHeight: 50)
            .padding(.horizontal, 8)
            .background(presentation.color.gradient, in: Capsule())
            .shadow(color: presentation.color.opacity(0.28), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(transitioning || model.busy || model.testingAll || !model.testingNodeIDs.isEmpty || model.selectingNodeID != nil)
        .accessibilityLabel(presentation.title)
        .accessibilityHint(model.connectionState == .disconnected ? "启动代理核心并启用系统代理" : "恢复原有系统网络设置并停止代理核心")
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    private var currentUploadRate: Int64 { model.samples.last?.upload ?? 0 }
    private var currentDownloadRate: Int64 { model.samples.last?.download ?? 0 }

    private var proxyStatus: (value: String, icon: String, color: Color) {
        switch model.connectionState {
        case .disconnected: ("已断开", "bolt.shield", .gray)
        case .connecting: ("连接中", "bolt.shield.fill", .blue)
        case .connected: ("已连接", "checkmark.shield.fill", .green)
        case .disconnecting: ("正在断开", "arrow.uturn.backward.circle", .orange)
        case .needsRepair: ("需要处理", "exclamationmark.shield.fill", .orange)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Header(title: "网络概览", subtitle: "实时查看流量、连接与自动分流状态")

                HStack(spacing: 14) {
                    ModeControl()
                    Spacer(minLength: 20)
                    ConnectionPowerButton()
                }

                if model.connectionState == .needsRepair {
                    Label("系统代理状态不完整。点击“安全断开”会先恢复系统网络，再停止核心。", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                LazyVGrid(
                    columns: [.init(.flexible()), .init(.flexible()), .init(.flexible()), .init(.flexible())],
                    spacing: 14
                ) {
                    StatCard(title: "代理状态", value: proxyStatus.value, icon: proxyStatus.icon, color: proxyStatus.color)
                    StatCard(title: "上传", value: "\(bytes(model.totalUpload)) · \(bytes(currentUploadRate))/s", icon: "arrow.up", color: .orange)
                    StatCard(title: "下载", value: "\(bytes(model.totalDownload)) · \(bytes(currentDownloadRate))/s", icon: "arrow.down", color: .blue)
                    StatCard(title: "当前连接", value: "\(model.connections.filter { $0.endedAt == nil }.count)", icon: "network", color: .purple)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("最近 60 秒流量")
                            .font(.headline)
                        Spacer()
                        if model.running, model.config.mode != .direct, model.coreMemory > 0 {
                            Text("核心内存 \(bytes(model.coreMemory))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TrafficChart(samples: model.samples)
                        .frame(height: 190)
                }
                .padding(18)
                .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.quaternary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("智能分流策略")
                            .font(.headline)
                        Spacer()
                        Text(model.config.mode.title)
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    HStack(spacing: 28) {
                        Label("域名与流量类别优先判断", systemImage: "1.circle.fill")
                        Label("目标服务器 IP 国内/境外复核", systemImage: "2.circle.fill")
                        Spacer()
                        Text("国内 DIRECT · 境外 PROXY")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.quaternary)
                }
            }
            .padding(28)
        }
    }
}

struct TrafficChart: View {
    let samples: [TrafficSample]

    var body: some View {
        Canvas { context, size in
            let maxValue = max(1, samples.map { max($0.upload, $0.download) }.max() ?? 1)
            func path(_ key: KeyPath<TrafficSample, Int64>) -> Path {
                var path = Path()
                for (index, sample) in samples.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(max(1, samples.count - 1))
                    let y = size.height - size.height * CGFloat(sample[keyPath: key]) / CGFloat(maxValue)
                    if index == 0 {
                        path.move(to: .init(x: x, y: y))
                    } else {
                        path.addLine(to: .init(x: x, y: y))
                    }
                }
                return path
            }
            context.stroke(path(\.download), with: .color(.blue), lineWidth: 2)
            context.stroke(path(\.upload), with: .color(.orange), lineWidth: 2)
        }
        .background(
            LinearGradient(colors: [.blue.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

struct NodesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var protocolFilter = "全部协议"
    @State private var regionFilter = "全部地区"

    private let grid = [GridItem(.adaptive(minimum: 215, maximum: 290), spacing: 14)]

    private var availableNodes: [ProxyNode] {
        model.config.nodes.filter(\.isSelectableProxy)
    }

    private var protocols: [String] {
        ["全部协议"] + Array(Set(availableNodes.map { $0.type.uppercased() })).sorted()
    }

    private var regions: [String] {
        ["全部地区"] + Array(Set(availableNodes.map(\.regionLabel))).sorted(by: regionOrder)
    }

    private var filteredNodes: [ProxyNode] {
        availableNodes.filter {
            (protocolFilter == "全部协议" || $0.type.uppercased() == protocolFilter)
                && (regionFilter == "全部地区" || $0.regionLabel == regionFilter)
        }
    }

    private var visibleRegions: [String] {
        Array(Set(filteredNodes.map(\.regionLabel))).sorted(by: regionOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                Header(
                    title: "代理节点",
                    subtitle: "真实 HTTP 延迟 · \(model.config.latencyTestTarget.title) · \(model.config.latencyTimeoutMilliseconds / 1_000) 秒超时"
                )
                Button {
                    let ids = availableNodes.map(\.id)
                    Task { await model.testAllNodes(ids: ids) }
                } label: {
                    if model.testingAll {
                        Label("测速中…", systemImage: "hourglass")
                    } else {
                        Label("一键测速", systemImage: "speedometer")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy || model.testingAll || !model.testingNodeIDs.isEmpty || model.selectingNodeID != nil || availableNodes.isEmpty)
            }

            HStack(spacing: 12) {
                Picker("地区", selection: $regionFilter) {
                    ForEach(regions, id: \.self) { region in
                        Text("\(region) (\(count(region: region)))").tag(region)
                    }
                }
                .frame(width: 190)

                Picker("协议", selection: $protocolFilter) {
                    ForEach(protocols, id: \.self) { value in
                        Text("\(value) (\(count(protocol: value)))").tag(value)
                    }
                }
                .frame(width: 210)

                Spacer()
                Text("显示 \(filteredNodes.count) / \(availableNodes.count) 个节点")
                    .foregroundStyle(.secondary)
            }

            if filteredNodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text(availableNodes.isEmpty ? "暂无可用节点" : "没有符合筛选条件的节点")
                        .font(.title3.bold())
                    Text(availableNodes.isEmpty ? "请先添加并更新订阅" : "请更改地区或协议筛选")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(visibleRegions, id: \.self) { region in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Text(region)
                                        .font(.headline)
                                    Text("\(nodes(in: region).count)")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.quaternary, in: Capsule())
                                }
                                LazyVGrid(columns: grid, alignment: .leading, spacing: 14) {
                                    ForEach(nodes(in: region)) { node in
                                        NodeCard(node: node)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(28)
    }

    private func nodes(in region: String) -> [ProxyNode] {
        filteredNodes
            .filter { $0.regionLabel == region }
            .sorted { lhs, rhs in
                if lhs.type != rhs.type { return lhs.type < rhs.type }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func count(region: String) -> Int {
        region == "全部地区" ? availableNodes.count : availableNodes.filter { $0.regionLabel == region }.count
    }

    private func count(protocol value: String) -> Int {
        value == "全部协议" ? availableNodes.count : availableNodes.filter { $0.type.uppercased() == value }.count
    }

    private func regionOrder(_ lhs: String, _ rhs: String) -> Bool {
        let order = ["香港", "台湾", "新加坡", "日本", "韩国", "美国", "加拿大", "英国", "德国", "法国", "荷兰", "澳大利亚", "菲律宾", "印度", "其他"]
        return (order.firstIndex(of: lhs) ?? order.count) < (order.firstIndex(of: rhs) ?? order.count)
    }
}

private struct NodeCard: View {
    @EnvironmentObject private var model: AppModel
    let node: ProxyNode

    private var selected: Bool { model.config.selectedNodeID == node.id }
    private var selecting: Bool { model.selectingNodeID == node.id }
    private var testing: Bool { model.testingAll || model.testingNodeIDs.contains(node.id) }

    private var latencyColor: Color {
        guard let latency = node.lastLatency else { return node.lastError == nil ? .secondary : .red }
        if latency < 100 { return .green }
        if latency <= 250 { return .orange }
        return .red
    }

    private var latencyText: String {
        if testing { return "测速中…" }
        if let latency = node.lastLatency { return "\(latency) ms" }
        if node.lastError != nil { return "超时" }
        return "未测速"
    }

    var body: some View {
        Button {
            Task { await model.selectNode(node.id) }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Text(node.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    if selecting {
                        ProgressView()
                            .controlSize(.small)
                    } else if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                    }
                }

                HStack(spacing: 6) {
                    Text(node.regionLabel)
                    Text("·")
                    Text(node.type.uppercased())
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                HStack {
                    Label("延迟", systemImage: "speedometer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if testing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(latencyText)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(latencyColor)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 134, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy || model.testingAll || !model.testingNodeIDs.isEmpty || model.selectingNodeID != nil)
        .help("点击切换到 \(node.name)")
        .accessibilityLabel("\(node.name)，\(node.regionLabel)，\(node.type.uppercased())")
        .accessibilityValue("\(selected ? "已选择" : "未选择")，延迟 \(latencyText)")
    }
}

struct SubscriptionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Header(title: "订阅管理", subtitle: "订阅地址只保存在本机，不会上传")
                Button("添加订阅", systemImage: "plus") { showingAdd = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.config.subscriptions.isEmpty)
            }
            List {
                ForEach(model.config.subscriptions) { item in
                    HStack(spacing: 14) {
                        Image(systemName: item.lastError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.lastError == nil ? Color.green : Color.orange)
                        VStack(alignment: .leading) {
                            Text(item.name)
                                .fontWeight(.semibold)
                            Text(item.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未更新")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = item.lastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Text("\(item.nodeIDs.count) 个节点")
                            .foregroundStyle(.secondary)
                        Button("更新") { Task { await model.refreshSubscription(item.id) } }
                            .disabled(model.busy || model.testingAll || !model.testingNodeIDs.isEmpty || model.selectingNodeID != nil)
                        Button(role: .destructive) { model.removeSubscription(item.id) } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(model.busy || model.testingAll || !model.testingNodeIDs.isEmpty || model.selectingNodeID != nil)
                    }
                    .padding(.vertical, 8)
                }
            }
            .listStyle(.inset)
        }
        .padding(28)
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionSheet(isPresented: $showingAdd)
        }
    }
}

struct AddSubscriptionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var name = "我的订阅"
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加订阅")
                .font(.title2.bold())
            TextField("名称", text: $name)
            SecureField("订阅地址", text: $url)
            Text("地址会在输入时隐藏，并仅保存在这台 Mac 的应用数据目录。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                Button("添加并更新") {
                    let subscriptionName = name
                    let subscriptionURL = url
                    isPresented = false
                    Task { await model.addSubscription(name: subscriptionName, url: subscriptionURL) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct RulesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Header(title: "智能分流", subtitle: "第一层识别域名类别，第二层判断目标服务器位于国内还是境外")
            List {
                ForEach(model.rules) { rule in
                    HStack {
                        Image(systemName: rule.action == .direct ? "arrow.right.circle.fill" : rule.action == .proxy ? "shield.lefthalf.filled" : "xmark.octagon.fill")
                            .foregroundStyle(rule.action == .direct ? Color.green : rule.action == .proxy ? Color.blue : Color.red)
                        VStack(alignment: .leading) {
                            Text(rule.name)
                                .fontWeight(.semibold)
                            Text("\(rule.kind.title) · \(rule.value.isEmpty ? "自动" : rule.value)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(rule.action.rawValue)
                            .font(.caption.monospaced().bold())
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.inset)
        }
        .padding(28)
    }
}

struct ConnectionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Header(title: "网络连接", subtitle: "来自 Mihomo 核心的真实连接快照，每秒更新")
            if model.connections.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text("暂无连接")
                        .font(.title3.bold())
                    Text(model.connectionState == .connected ? "打开网页或应用后，活动连接会显示在这里" : "连接网络后，活动连接会显示在这里")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.connections) {
                    TableColumn("目标") {
                        Text("\($0.host):\($0.port)")
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("类别") { Text($0.category.uppercased()) }
                        .width(100)
                    TableColumn("路线") {
                        Text($0.action.rawValue)
                            .foregroundStyle($0.action == .direct ? Color.green : Color.blue)
                    }
                    .width(90)
                    TableColumn("流量") {
                        Text("↑\(bytes($0.uploaded))  ↓\(bytes($0.downloaded))")
                    }
                    .width(180)
                    TableColumn("状态") { Text($0.status) }
                        .width(80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding(28)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("连接") {
                Toggle("启动应用时自动连接", isOn: Binding(
                    get: { model.config.autoConnectOnLaunch },
                    set: { model.setAutoConnectOnLaunch($0) }
                ))
                Text("自动连接会同时启动代理核心并应用系统代理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("代理核心") {
                TextField("监听端口", value: $model.config.proxyPort, format: .number)
                    .onSubmit { model.save() }
                Text("监听端口仅用于直连检查模式；规则和全局模式由核心自动分配端口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("真实测速") {
                Picker("测试目标", selection: $model.config.latencyTestTarget) {
                    ForEach(LatencyTestTarget.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: model.config.latencyTestTarget) { _ in model.save() }
                Picker("超时时间", selection: $model.config.latencyTimeoutMilliseconds) {
                    Text("5 秒").tag(5_000)
                    Text("8 秒").tag(8_000)
                    Text("12 秒").tag(12_000)
                }
                .onChange(of: model.config.latencyTimeoutMilliseconds) { _ in model.save() }
                Text("测速会让 Mihomo 通过节点访问所选 HTTP 目标；不同软件必须使用相同目标和超时设置才可横向比较。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("隐私与安全") {
                Label("订阅令牌只保存在本机应用数据目录", systemImage: "lock.shield")
                Label("代理仅监听 127.0.0.1，不接受局域网连接", systemImage: "laptopcomputer.and.iphone")
            }
            Section {
                Text("智连 0.6.1 · 原生 macOS 应用")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
