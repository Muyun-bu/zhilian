import SwiftUI

@main
struct ZhilianApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("智连") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1050, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 390)
        }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case dashboard = "概览"
    case nodes = "节点"
    case subscriptions = "订阅"
    case rules = "分流规则"
    case connections = "连接"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .nodes: "server.rack"
        case .subscriptions: "link"
        case .rules: "arrow.triangle.branch"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page: Page = .dashboard

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                brand
                navigation
                Spacer(minLength: 16)
                CurrentNodeSidebarCard()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
            }
            .navigationSplitViewColumnWidth(min: 248, ideal: 260, max: 280)
        } detail: {
            detail
                .background(Color(nsColor: .windowBackgroundColor))
                .alert("智连", isPresented: Binding(
                    get: { model.notice != nil },
                    set: { if !$0 { model.notice = nil } }
                )) {
                    Button("好") { model.notice = nil }
                } message: {
                    Text(model.notice ?? "")
                }
        }
        .onAppear {
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let icon = NSImage(contentsOf: iconURL) {
                NSApp.applicationIconImage = icon
            }
        }
    }

    private var brand: some View {
        HStack(spacing: 13) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text("智连")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("智能网络分流")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    private var navigation: some View {
        VStack(spacing: 7) {
            ForEach(Page.allCases) { item in
                SidebarNavigationButton(item: item, selected: page == item) {
                    page = item
                }
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .dashboard: DashboardView()
        case .nodes: NodesView()
        case .subscriptions: SubscriptionsView()
        case .rules: RulesView()
        case .connections: ConnectionsView()
        case .settings: SettingsView()
        }
    }
}

private struct SidebarNavigationButton: View {
    let item: Page
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: item.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? .white : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(selected ? Color.accentColor : Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(item.rawValue)
                    .font(.system(size: 15, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.28) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开\(item.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CurrentNodeSidebarCard: View {
    @EnvironmentObject private var model: AppModel

    private var status: (text: String, color: Color) {
        switch model.connectionState {
        case .disconnected: ("未连接", .secondary)
        case .connecting: ("正在连接", .blue)
        case .connected: ("已连接", .green)
        case .disconnecting: ("正在恢复网络", .orange)
        case .needsRepair: ("需要处理", .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("当前连接")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 7, height: 7)
                    Text(status.text)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(status.color)
                }
            }

            if model.config.mode == .direct, model.running {
                Text("直连模式")
                    .font(.headline)
                Text("本机网络 · DIRECT")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let node = model.selectedNode {
                Text(node.name)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(node.regionLabel)
                    Text("·")
                    Text(node.type.uppercased())
                    if let latency = node.lastLatency {
                        Text("·")
                        Text("\(latency) ms")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else {
                Text("尚未选择节点")
                    .font(.headline)
                Text("请先添加订阅并选择节点")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.quaternary)
        }
        .accessibilityElement(children: .combine)
    }
}
