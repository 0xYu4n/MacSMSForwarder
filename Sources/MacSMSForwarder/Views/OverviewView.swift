import ForwarderCore
import GRDB
import SwiftUI

/// 概览页：运行状态、今日统计、权限检查与快速上手
struct OverviewView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selection: SidebarItem?

  /// 规则数和通道数（用于判断是否完成初始配置）
  @StateObject private var counts = DBObserver<(rules: Int, channels: Int)>(initial: (0, 0)) { db in
    (try ForwardRule.fetchCount(db), try ForwardChannelRecord.fetchCount(db))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        PageHeader(title: "概览", subtitle: "把 Mac「信息」收到的 iMessage 和短信，自动转发到 Bark 与各类消息网关")

        // 统计卡片
        HStack(spacing: 12) {
          StatCard(
            title: "运行状态", value: model.healthText, symbol: "dot.radiowaves.left.and.right",
            tint: model.health.color)
          StatCard(title: "今日收到", value: "\(model.todayReceived)", symbol: "tray.and.arrow.down", tint: .blue)
          StatCard(title: "今日转发", value: "\(model.todayForwarded)", symbol: "paperplane", tint: .purple)
        }

        // 功能开关
        HStack(spacing: 12) {
          FeatureCard(
            title: "接收转发", detail: "收到消息后按规则推送到通道", symbol: "tray.and.arrow.down",
            isOn: Binding(get: { model.receiveEnabled }, set: { model.setReceiveEnabled($0) }))
          FeatureCard(
            title: "发送", detail: "通过界面或 HTTP API 发送 iMessage", symbol: "paperplane",
            isOn: Binding(get: { model.sendEnabled }, set: { model.setSendEnabled($0) }))
        }

        // 权限检查：只显示已开启功能所需的权限
        Card {
          Text("权限检查").font(.headline)
          if model.receiveEnabled {
            PermissionRow(
              title: "完全磁盘访问",
              detail: "读取「信息」数据库以接收消息，必需",
              state: model.fullDiskAccess,
              actionTitle: "前往授权"
            ) {
              Permissions.openFullDiskAccessSettings()
            }
            Divider()
          }
          if model.sendEnabled {
            PermissionRow(
              title: "自动化：控制「信息」",
              detail: "通过界面或 API 发送 iMessage 时需要",
              state: model.automation,
              actionTitle: model.automation == .denied ? "前往设置" : "请求授权"
            ) {
              if model.automation == .denied {
                Permissions.openAutomationSettings()
              } else {
                model.requestAutomation()
              }
            }
            Divider()
          }
          PermissionRow(
            title: "「信息」App",
            detail: "需保持运行（可隐藏窗口），并登录 Apple ID",
            state: model.messagesRunning ? .granted : .denied,
            actionTitle: "后台启动"
          ) {
            Permissions.launchMessagesInBackground()
          }
          if model.receiveEnabled, model.fullDiskAccess != .granted {
            Text("在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」中点 +，添加「Mac短信转发」并打开开关。授权后本页会自动刷新。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        // 快速上手
        Card {
          Text("快速上手").font(.headline)
          StepRow(index: 1, title: "添加转发通道", detail: "例如 Bark：填入设备 Key 即可", done: counts.value.channels > 0) {
            selection = .channels
          }
          StepRow(index: 2, title: "创建转发规则", detail: "不加条件即转发全部消息", done: counts.value.rules > 0) {
            selection = .rules
          }
          StepRow(index: 3, title: "（可选）开启 HTTP API", detail: "供自动化工具调用，发送 iMessage", done: model.serverRunning) {
            selection = .api
          }
        }
      }
      .padding(24)
    }
  }
}

/// 功能开关卡片
private struct FeatureCard: View {
  var title: String
  var detail: String
  var symbol: String
  @Binding var isOn: Bool

  var body: some View {
    Card {
      HStack(alignment: .top) {
        Image(systemName: symbol)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(isOn ? Color.accentColor : .secondary)
          .frame(width: 30, height: 30)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill((isOn ? Color.accentColor : Color.secondary).opacity(0.12)))
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.body.weight(.semibold))
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Toggle("", isOn: $isOn)
          .toggleStyle(.switch)
          .labelsHidden()
      }
    }
    .opacity(isOn ? 1 : 0.75)
  }
}

/// 统计卡片
private struct StatCard: View {
  var title: String
  var value: String
  var symbol: String
  var tint: Color

  var body: some View {
    Card {
      HStack {
        Image(systemName: symbol)
          .foregroundStyle(tint)
          .font(.system(size: 14, weight: .semibold))
        Text(title).font(.callout).foregroundStyle(.secondary)
      }
      Text(value)
        .font(.system(size: 22, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
  }
}

/// 权限行
private struct PermissionRow: View {
  var title: String
  var detail: String
  var state: PermissionState
  var actionTitle: String
  var action: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .font(.system(size: 18))
        .foregroundStyle(state == .granted ? Color.green : (state == .denied ? .red : .orange))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.body.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if state != .granted {
        Button(actionTitle, action: action)
          .controlSize(.small)
      } else {
        Text("已就绪").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

/// 上手步骤行
private struct StepRow: View {
  var index: Int
  var title: String
  var detail: String
  var done: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        ZStack {
          Circle()
            .fill(done ? Color.green.opacity(0.15) : Color.accentColor.opacity(0.12))
            .frame(width: 26, height: 26)
          if done {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
          } else {
            Text("\(index)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
          }
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.body.weight(.medium))
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
