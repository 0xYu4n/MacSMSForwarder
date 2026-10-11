import ForwarderCore
import SwiftUI

/// 菜单栏弹出面板
struct MenuBarView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // 状态
      HStack(spacing: 8) {
        StatusDot(color: model.health.color, size: 9)
        Text(model.healthText).font(.headline)
        Spacer()
      }

      // 今日统计
      HStack(spacing: 10) {
        MiniStat(title: "今日收到", value: model.todayReceived)
        MiniStat(title: "今日转发", value: model.todayForwarded)
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Toggle(
          "接收转发",
          isOn: Binding(get: { model.receiveEnabled }, set: { model.setReceiveEnabled($0) }))
        Toggle(
          "发送",
          isOn: Binding(get: { model.sendEnabled }, set: { model.setSendEnabled($0) }))
        if model.receiveEnabled {
          Toggle(
            "暂停推送",
            isOn: Binding(get: { model.paused }, set: { model.setPaused($0) }))
        }
      }
      .toggleStyle(.switch)
      .controlSize(.small)

      Divider()

      HStack {
        Button("打开主窗口") {
          openWindow(id: "main")
          NSApp.activate(ignoringOtherApps: true)
        }
        Spacer()
        Button("退出") { NSApp.terminate(nil) }
      }
      .controlSize(.small)
    }
    .padding(14)
    .frame(width: 260)
  }
}

/// 菜单栏中的小统计块
private struct MiniStat: View {
  var title: String
  var value: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text("\(value)").font(.system(size: 18, weight: .semibold, design: .rounded))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
  }
}
