import SwiftUI

@main
struct ZhilianApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("智连") { RootView().environmentObject(model).frame(minWidth: 1050, minHeight: 680) }
            .windowStyle(.hiddenTitleBar)
        Settings { SettingsView().environmentObject(model).frame(width: 520, height: 360) }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case dashboard = "概览", nodes = "节点", subscriptions = "订阅", rules = "分流规则", connections = "连接", settings = "设置"
    var id: String { rawValue }
    var icon: String { switch self { case .dashboard: "square.grid.2x2"; case .nodes: "server.rack"; case .subscriptions: "link"; case .rules: "arrow.triangle.branch"; case .connections: "point.3.connected.trianglepath.dotted"; case .settings: "gearshape" } }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: Page? = .dashboard
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 14) {
                HStack(spacing: 12) { Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40); VStack(alignment: .leading) { Text("智连").font(.title2.bold()); Text("智能网络分流").foregroundStyle(.secondary).font(.caption) } }.padding(.top, 18)
                List(Page.allCases, selection: $page) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }.listStyle(.sidebar)
                Spacer()
                VStack(alignment: .leading, spacing: 8) { Label(model.running ? "代理核心运行中" : "代理核心已停止", systemImage: model.running ? "checkmark.circle.fill" : "pause.circle").foregroundStyle(model.running ? .green : .secondary); Text(model.running && model.config.mode != .direct ? "Mihomo 直连模式" : "127.0.0.1:\(model.config.proxyPort)").font(.caption.monospaced()).foregroundStyle(.secondary) }.padding()
            }.navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            Group { switch page ?? .dashboard { case .dashboard: DashboardView(); case .nodes: NodesView(); case .subscriptions: SubscriptionsView(); case .rules: RulesView(); case .connections: ConnectionsView(); case .settings: SettingsView() } }
                .background(Color(nsColor: .windowBackgroundColor))
                .alert("智连", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) { Button("好") { model.notice = nil } } message: { Text(model.notice ?? "") }
        }.onAppear {
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let icon = NSImage(contentsOf: iconURL) { NSApp.applicationIconImage = icon }
        }
    }
}
