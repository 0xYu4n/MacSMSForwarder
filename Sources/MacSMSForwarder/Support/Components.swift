import ForwarderCore
import SwiftUI

// 通用界面组件：保持全 App 视觉一致、简洁

/// 状态圆点
struct StatusDot: View {
  var color: Color
  var size: CGFloat = 8

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: size, height: size)
      .shadow(color: color.opacity(0.5), radius: 3)
  }
}

extension AppModel.Health {
  /// 健康度对应的颜色
  var color: Color {
    switch self {
    case .ok: return .green
    case .warning: return .orange
    case .error: return .red
    }
  }
}

/// 圆角卡片容器
struct Card<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.06))
    )
  }
}

/// 页面标题栏：大标题 + 副标题 + 右侧操作区
struct PageHeader<Trailing: View>: View {
  var title: String
  var subtitle: String?
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 22, weight: .semibold))
        if let subtitle {
          Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
      }
      Spacer()
      trailing
    }
  }
}

extension PageHeader where Trailing == EmptyView {
  init(title: String, subtitle: String? = nil) {
    self.init(title: title, subtitle: subtitle) { EmptyView() }
  }
}

/// 空状态占位
struct EmptyStateView: View {
  var symbol: String
  var title: String
  var message: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 36, weight: .light))
        .foregroundStyle(.tertiary)
      Text(title).font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}

/// 小号胶囊标签（服务类型、状态等）
struct Tag: View {
  var text: String
  var color: Color = .secondary

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(color.opacity(0.14)))
      .foregroundStyle(color)
  }
}

extension StoredMessage {
  /// 服务类型标签颜色：iMessage 蓝、短信绿
  var serviceColor: Color {
    service.lowercased().contains("imessage") ? .blue : .green
  }

  /// 发送状态文字
  var sendStateText: String? {
    switch sendState {
    case .none: return nil
    case .pending: return "发送中"
    case .sent: return "已发送"
    case .delivered: return "已送达"
    case .failed: return "失败"
    }
  }

  var sendStateColor: Color {
    switch sendState {
    case .failed: return .red
    case .delivered: return .green
    case .pending: return .orange
    default: return .secondary
    }
  }
}

/// 日期显示格式
enum DateText {
  private static let time: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
  }()

  private static let full: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
  }()

  private static let day: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "M月d日 HH:mm"
    return f
  }()

  /// 今天显示时间，其他日期显示「月日 时间」
  static func short(_ date: Date) -> String {
    Calendar.current.isDateInToday(date) ? time.string(from: date) : day.string(from: date)
  }

  static func long(_ date: Date) -> String { full.string(from: date) }
}
