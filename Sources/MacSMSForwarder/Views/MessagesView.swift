import ForwarderCore
import GRDB
import SwiftUI

/// 消息页：最近消息列表（支持搜索）+ 发送新消息
struct MessagesView: View {
  @EnvironmentObject private var model: AppModel
  @State private var search = ""
  @State private var showCompose = false

  /// 最近 500 条消息
  @StateObject private var messages = DBObserver<[StoredMessage]>(initial: []) { db in
    try StoredMessage.order(Column("id").desc).limit(500).fetchAll(db)
  }

  /// 按搜索词过滤（号码或正文）
  private var filtered: [StoredMessage] {
    let keyword = search.trimmingCharacters(in: .whitespaces)
    guard !keyword.isEmpty else { return messages.value }
    return messages.value.filter {
      $0.handle.localizedCaseInsensitiveContains(keyword)
        || $0.text.localizedCaseInsensitiveContains(keyword)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(title: "消息", subtitle: "收到与发出的 iMessage / 短信") {
        Button {
          showCompose = true
        } label: {
          Label("发送消息", systemImage: "square.and.pencil")
        }
        .disabled(!model.sendEnabled)
        .help(model.sendEnabled ? "发送 iMessage / 短信" : "发送功能已关闭，可在设置中开启")
      }
      .padding([.horizontal, .top], 24)
      .padding(.bottom, 12)

      if messages.value.isEmpty {
        EmptyStateView(
          symbol: "bubble.left.and.bubble.right",
          title: "暂无消息",
          message: "启动后收到的新消息会显示在这里。历史消息不会被导入或转发。")
      } else {
        List(filtered) { message in
          MessageRow(message: message)
        }
        .listStyle(.inset)
        .searchable(text: $search, placement: .toolbar, prompt: "搜索号码或内容")
      }
    }
    .sheet(isPresented: $showCompose) {
      ComposeView()
        .environmentObject(model)
    }
  }
}

/// 单条消息行
private struct MessageRow: View {
  let message: StoredMessage

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      // 方向图标
      Image(systemName: message.direction == .incoming ? "arrow.down.left" : "arrow.up.right")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(message.direction == .incoming ? Color.blue : Color.secondary)
        .frame(width: 22, height: 22)
        .background(Circle().fill(Color.primary.opacity(0.05)))

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(message.handle).font(.body.weight(.medium)).lineLimit(1)
          Tag(text: message.service, color: message.serviceColor)
          if message.isGroup { Tag(text: "群聊") }
          if let code = message.direction == .incoming ? CodeExtractor.extract(from: message.text) : nil {
            Tag(text: "验证码 \(code)", color: .orange)
          }
          if let state = message.sendStateText {
            Tag(text: state, color: message.sendStateColor)
          }
          Spacer()
          Text(DateText.short(message.date))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(message.text.isEmpty ? "［附件］" : message.text)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .textSelection(.enabled)
        if let error = message.errorMessage {
          Text(error).font(.caption).foregroundStyle(.red)
        }
      }
    }
    .padding(.vertical, 4)
  }
}

/// 发送消息表单
struct ComposeView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var to = ""
  @State private var text = ""
  @State private var service = "auto"
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("发送消息").font(.title3.weight(.semibold))
      Form {
        TextField("收件人", text: $to, prompt: Text("+8613800138000 或 Apple ID 邮箱"))
        Picker("通道", selection: $service) {
          Text("自动（优先 iMessage）").tag("auto")
          Text("iMessage").tag("imessage")
          Text("短信").tag("sms")
        }
        TextField("内容", text: $text, prompt: Text("消息内容"), axis: .vertical)
          .lineLimit(4...8)
      }
      .formStyle(.grouped)
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("发送") {
          do {
            _ = try model.sendService.send(
              SendRequest(to: to, text: text, service: service), source: .ui)
            dismiss()
          } catch {
            self.error = error.localizedDescription
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(to.isEmpty || text.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 460)
  }
}
