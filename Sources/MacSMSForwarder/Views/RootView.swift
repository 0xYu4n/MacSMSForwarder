import ForwarderCore
import SwiftUI

/// 侧栏页面
enum SidebarItem: String, CaseIterable, Identifiable {
  case overview
  case messages
  case rules
  case channels
  case api
  case logs
  case settings
  case donate

  var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: return "概览"
    case .messages: return "消息"
    case .rules: return "转发规则"
    case .channels: return "转发通道"
    case .api: return "HTTP API"
    case .logs: return "转发日志"
    case .settings: return "设置"
    case .donate: return "打赏支持"
    }
  }

  var symbol: String {
    switch self {
    case .overview: return "gauge.with.dots.needle.33percent"
    case .messages: return "bubble.left.and.bubble.right"
    case .rules: return "line.3.horizontal.decrease.circle"
    case .channels: return "paperplane"
    case .api: return "chevron.left.forwardslash.chevron.right"
    case .logs: return "list.bullet.rectangle"
    case .settings: return "gearshape"
    case .donate: return "cup.and.saucer"
    }
  }
}

/// 主窗口根视图：左侧导航 + 右侧内容
struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selection: SidebarItem? = .overview

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section {
          ForEach([SidebarItem.overview, .messages]) { item in
            Label(item.title, systemImage: item.symbol).tag(item)
          }
        }
        Section("转发") {
          ForEach([SidebarItem.rules, .channels, .logs]) { item in
            Label(item.title, systemImage: item.symbol).tag(item)
          }
        }
        Section("其他") {
          ForEach([SidebarItem.api, .settings, .donate]) { item in
            Label(item.title, systemImage: item.symbol).tag(item)
          }
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
      .safeAreaInset(edge: .bottom) {
        // 侧栏底部：运行状态
        HStack(spacing: 8) {
          StatusDot(color: model.health.color)
          Text(model.healthText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
    } detail: {
      Group {
        switch selection ?? .overview {
        case .overview: OverviewView(selection: $selection)
        case .messages: MessagesView()
        case .rules: RulesView()
        case .channels: ChannelsView()
        case .api: APIView()
        case .logs: LogsView()
        case .settings: SettingsView()
        case .donate: DonateView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .alert(
      "数据库错误",
      isPresented: .constant(model.fatalError != nil),
      actions: { Button("好") { model.fatalError = nil } },
      message: { Text(model.fatalError ?? "") })
  }
}
