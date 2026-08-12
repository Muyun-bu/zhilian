import SwiftUI

private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) }

struct Header: View {
    let title: String; let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.largeTitle.bold()); Text(subtitle).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
}

struct StatCard: View {
    let title: String; let value: String; let icon: String; let color: Color
    var body: some View { HStack(spacing: 14) { Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 42, height: 42).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading) { Text(title).foregroundStyle(.secondary).font(.caption); Text(value).font(.title2.bold()).lineLimit(1) }; Spacer() }.padding(18).background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary)) }
}

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            Header(title: "网络概览", subtitle: "实时查看流量、连接与自动分流状态")
            HStack { Picker("模式", selection: $model.config.mode) { ForEach(ProxyMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: 310).onChange(of: model.config.mode) { _ in model.save() }; Spacer(); Toggle("系统代理", isOn: Binding(get: { model.systemProxy }, set: { model.setSystemProxy($0) })).toggleStyle(.switch); Button { model.toggleServer() } label: { Label(model.running ? "停止代理" : "启动代理", systemImage: model.running ? "stop.fill" : "power").font(.title3.bold()).frame(minWidth: 112, minHeight: 32) }.buttonStyle(.borderedProminent).controlSize(.large).tint(model.running ? .red : .accentColor) }
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 14) {
                StatCard(title: "代理状态", value: model.running ? "已运行" : "已停止", icon: "bolt.shield.fill", color: model.running ? .green : .gray)
                StatCard(title: "上传流量", value: bytes(model.totalUpload), icon: "arrow.up", color: .orange)
                StatCard(title: "下载流量", value: bytes(model.totalDownload), icon: "arrow.down", color: .blue)
                StatCard(title: "当前连接", value: "\(model.connections.filter { $0.endedAt == nil }.count)", icon: "network", color: .purple)
            }
            VStack(alignment: .leading, spacing: 12) { Text("最近 60 秒流量").font(.headline); TrafficChart(samples: model.samples).frame(height: 190) }.padding(18).background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 12) { Text("当前节点").font(.headline); if let node = model.selectedNode { Text(node.name).font(.title3.bold()); Text("\(node.type.uppercased()) · \(node.host):\(node.port)").foregroundStyle(.secondary) } else { Text("请添加订阅并选择节点").foregroundStyle(.secondary) } }.padding(18).frame(maxWidth: .infinity, minHeight: 120, alignment: .leading).background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 10) { Text("分流策略").font(.headline); Label("域名与流量类别优先判断", systemImage: "1.circle.fill"); Label("目标服务器 IP 国内/境外复核", systemImage: "2.circle.fill"); Text("国内 DIRECT · 境外 PROXY").foregroundStyle(.secondary).font(.caption) }.padding(18).frame(maxWidth: .infinity, minHeight: 120, alignment: .leading).background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
            }
        }.padding(28) }
    }
}

struct TrafficChart: View {
    let samples: [TrafficSample]
    var body: some View { Canvas { context, size in
        let maxValue = max(1, samples.map { max($0.upload, $0.download) }.max() ?? 1)
        func path(_ key: KeyPath<TrafficSample, Int64>) -> Path { var p = Path(); for (index, sample) in samples.enumerated() { let x = size.width * CGFloat(index) / CGFloat(max(1, samples.count - 1)); let y = size.height - size.height * CGFloat(sample[keyPath: key]) / CGFloat(maxValue); index == 0 ? p.move(to: .init(x: x, y: y)) : p.addLine(to: .init(x: x, y: y)) }; return p }
        context.stroke(path(\.download), with: .color(.blue), lineWidth: 2); context.stroke(path(\.upload), with: .color(.orange), lineWidth: 2)
    }.background(LinearGradient(colors: [.blue.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 10)) }
}

struct NodesView: View {
    @EnvironmentObject var model: AppModel
    @State private var protocolFilter = "全部协议"
    @State private var regionFilter = "全部地区"
    private var protocols: [String] { ["全部协议"] + Array(Set(model.config.nodes.map { $0.type.uppercased() })).sorted() }
    private var regions: [String] { ["全部地区"] + Array(Set(model.config.nodes.map(nodeRegion))).sorted() }
    private var filteredNodes: [ProxyNode] { model.config.nodes.filter { (protocolFilter == "全部协议" || $0.type.uppercased() == protocolFilter) && (regionFilter == "全部地区" || nodeRegion($0) == regionFilter) } }
    var body: some View { VStack(alignment: .leading, spacing: 20) { HStack { Header(title: "代理节点", subtitle: "按地区和协议分类，选择节点并检测真实连接延迟"); Button { Task { await model.testAllNodes() } } label: { Label(model.testingAll ? "测速中…" : "一键测速", systemImage: "speedometer") }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.testingAll || model.config.nodes.isEmpty) }
        HStack(spacing: 12) { Picker("地区", selection: $regionFilter) { ForEach(regions, id: \.self) { Text("\($0) (\(count(region: $0)))").tag($0) } }.frame(width: 190); Picker("协议", selection: $protocolFilter) { ForEach(protocols, id: \.self) { Text("\($0) (\(count(protocol: $0)))").tag($0) } }.frame(width: 210); Spacer(); Text("显示 \(filteredNodes.count) / \(model.config.nodes.count) 个节点").foregroundStyle(.secondary) }
        Table(filteredNodes) {
        TableColumn("节点") { node in VStack(alignment: .leading) { Text(node.name).fontWeight(.semibold); Text("\(node.host):\(node.port)").font(.caption.monospaced()).foregroundStyle(.secondary) } }
        TableColumn("地区") { Text(nodeRegion($0)) }.width(70)
        TableColumn("协议") { Text($0.type.uppercased()) }.width(75)
        TableColumn("延迟") { node in Text(node.lastLatency.map { "\($0) ms" } ?? (node.lastError == nil ? "未测试" : "失败")).foregroundStyle(node.lastLatency == nil ? Color.secondary : Color.green) }.width(90)
        TableColumn("状态") { node in HStack { Button(model.config.selectedNodeID == node.id ? "已选择" : "选择") { Task { await model.selectNode(node.id) } }.disabled(!node.supported); Button("测速") { Task { await model.testNode(node.id) } } } }.width(150)
    }.tableStyle(.inset(alternatesRowBackgrounds: true)) }.padding(28) }

    private func nodeRegion(_ node: ProxyNode) -> String {
        let value = node.name.lowercased()
        if ["剩余流量", "套餐到期", "到期时间"].contains(where: { node.name.contains($0) }) { return "账户信息" }
        let mappings = [("香港", ["香港", "hong kong", "hk"]), ("台湾", ["台湾", "taiwan", "tw"]), ("新加坡", ["新加坡", "singapore", "sg"]), ("日本", ["日本", "japan", "jp"]), ("美国", ["美国", "united states", "usa", "us"]), ("韩国", ["韩国", "korea", "kr"]), ("英国", ["英国", "united kingdom", "uk"])]
        return mappings.first(where: { $0.1.contains(where: { value.contains($0) }) })?.0 ?? "其他"
    }
    private func count(region: String) -> Int { region == "全部地区" ? model.config.nodes.count : model.config.nodes.filter { nodeRegion($0) == region }.count }
    private func count(protocol value: String) -> Int { value == "全部协议" ? model.config.nodes.count : model.config.nodes.filter { $0.type.uppercased() == value }.count }
}

struct SubscriptionsView: View {
    @EnvironmentObject var model: AppModel; @State private var showingAdd = false
    var body: some View { VStack(alignment: .leading, spacing: 20) { HStack { Header(title: "订阅管理", subtitle: "订阅地址只保存在本机，不会上传"); Button("添加订阅", systemImage: "plus") { showingAdd = true }.buttonStyle(.borderedProminent) }
        List { ForEach(model.config.subscriptions) { item in HStack(spacing: 14) { Image(systemName: item.lastError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(item.lastError == nil ? .green : .orange); VStack(alignment: .leading) { Text(item.name).fontWeight(.semibold); Text(item.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未更新").font(.caption).foregroundStyle(.secondary); if let error = item.lastError { Text(error).font(.caption).foregroundStyle(.red) } }; Spacer(); Text("\(item.nodeIDs.count) 个节点").foregroundStyle(.secondary); Button("更新") { Task { await model.refreshSubscription(item.id) } }.disabled(model.busy); Button(role: .destructive) { model.removeSubscription(item.id) } label: { Image(systemName: "trash") } } .padding(.vertical, 8) } }.listStyle(.inset)
    }.padding(28).sheet(isPresented: $showingAdd) { AddSubscriptionSheet(isPresented: $showingAdd) } }
}

struct AddSubscriptionSheet: View {
    @EnvironmentObject var model: AppModel; @Binding var isPresented: Bool; @State private var name = "我的订阅"; @State private var url = ""
    var body: some View { VStack(alignment: .leading, spacing: 18) { Text("添加订阅").font(.title2.bold()); TextField("名称", text: $name); SecureField("订阅地址", text: $url); Text("地址包含的令牌将加密显示，并仅保存在这台 Mac。 ").font(.caption).foregroundStyle(.secondary); HStack { Spacer(); Button("取消") { isPresented = false }; Button("添加并更新") { let n = name, u = url; isPresented = false; Task { await model.addSubscription(name: n, url: u) } }.buttonStyle(.borderedProminent).disabled(url.isEmpty) } }.padding(24).frame(width: 480) }
}

struct RulesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { VStack(alignment: .leading, spacing: 20) { Header(title: "智能分流", subtitle: "第一层识别域名类别，第二层判断目标服务器位于国内还是境外"); List { ForEach(model.rules) { rule in HStack { Image(systemName: rule.action == .direct ? "arrow.right.circle.fill" : rule.action == .proxy ? "shield.lefthalf.filled" : "xmark.octagon.fill").foregroundStyle(rule.action == .direct ? .green : rule.action == .proxy ? .blue : .red); VStack(alignment: .leading) { Text(rule.name).fontWeight(.semibold); Text("\(rule.kind.title) · \(rule.value.isEmpty ? "自动" : rule.value)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(rule.action.rawValue).font(.caption.monospaced().bold()).padding(.horizontal, 9).padding(.vertical, 4).background(.quaternary, in: Capsule()) } .padding(.vertical, 6) } }.listStyle(.inset) }.padding(28) }
}

struct ConnectionsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { VStack(alignment: .leading, spacing: 20) { Header(title: "网络连接", subtitle: "查看每个目标的识别结果、命中规则和流量"); Table(model.connections) {
        TableColumn("目标") { Text("\($0.host):\($0.port)").font(.system(.body, design: .monospaced)) }
        TableColumn("类别") { Text($0.category.uppercased()) }.width(80)
        TableColumn("路线") { Text($0.action.rawValue).foregroundStyle($0.action == .direct ? .green : .blue) }.width(80)
        TableColumn("判断依据") { Text($0.rule) }
        TableColumn("流量") { Text("↑\(bytes($0.uploaded)) ↓\(bytes($0.downloaded))") }.width(150)
        TableColumn("状态") { Text($0.status) }.width(60)
    }.tableStyle(.inset(alternatesRowBackgrounds: true)) }.padding(28) }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section("本地代理") {
                TextField("监听端口", value: $model.config.proxyPort, format: .number).onSubmit { model.save() }
                Toggle("启动时开启本地代理", isOn: $model.config.proxyEnabled).onChange(of: model.config.proxyEnabled) { _ in model.save() }
            }
            Section("隐私与安全") {
                Label("订阅令牌只保存在本机应用数据目录", systemImage: "lock.shield")
                Label("代理仅监听 127.0.0.1，不接受局域网连接", systemImage: "laptopcomputer.and.iphone")
            }
            Section { Text("智连 0.4.5 · 原生 macOS 应用").foregroundStyle(.secondary) }
        }.formStyle(.grouped).padding()
    }
}
