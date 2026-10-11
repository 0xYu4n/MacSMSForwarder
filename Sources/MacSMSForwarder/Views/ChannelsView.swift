import ForwarderCore
import GRDB
import SwiftUI

/// 转发通道页
struct ChannelsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var editing: ForwardChannelRecord?

  @StateObject private var channels = DBObserver<[ForwardChannelRecord]>(initial: []) { db in
    try ForwardChannelRecord.order(Column("id")).fetchAll(db)
  }

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(title: "转发通道", subtitle: "消息推送的目的地") {
        Menu {
          ForEach(["手机推送", "IM 机器人", "自建推送", "通用"], id: \.self) { group in
            Section(group) {
              ForEach(ChannelType.allCases.filter { $0.group == group }) { type in
                Button {
                  editing = ChannelCatalog.newChannel(type)
                } label: {
                  Label(type.title, systemImage: type.symbol)
                }
              }
            }
          }
        } label: {
          Label("添加通道", systemImage: "plus")
        }
        .fixedSize()
      }
      .padding([.horizontal, .top], 24)
      .padding(.bottom, 12)

      if channels.value.isEmpty {
        EmptyStateView(
          symbol: "paperplane",
          title: "还没有通道",
          message: "支持 Bark、企业微信、钉钉、飞书、Telegram、PushDeer、Server酱、PushPlus、ntfy、Gotify 与通用 Webhook。")
      } else {
        List {
          ForEach(channels.value) { channel in
            ChannelRow(channel: channel)
              .contentShape(Rectangle())
              .onTapGesture(count: 2) { editing = channel }
              .contextMenu {
                Button("编辑") { editing = channel }
                Button("删除", role: .destructive) { delete(channel) }
              }
          }
        }
        .listStyle(.inset)
      }
    }
    .sheet(item: $editing) { channel in
      ChannelEditor(channel: channel)
        .environmentObject(model)
    }
  }

  private func delete(_ channel: ForwardChannelRecord) {
    _ = try? model.database.writer.write { db in
      // 同时从所有规则中移除该通道
      if let id = channel.id {
        for var rule in try ForwardRule.fetchAll(db) where rule.channelIDs.contains(id) {
          rule.channelIDs.removeAll { $0 == id }
          try rule.update(db)
        }
      }
      try channel.delete(db)
    }
  }
}

/// 通道行
private struct ChannelRow: View {
  @EnvironmentObject private var model: AppModel
  let channel: ForwardChannelRecord
  @State private var testing = false
  @State private var testResult: ForwardResult?

  private var detail: String {
    ChannelCatalog.summary(channel)
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: channel.type.symbol)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .frame(width: 32, height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(channel.name).font(.body.weight(.medium))
          Tag(text: channel.type.title)
          if !channel.enabled { Tag(text: "已停用", color: .orange) }
        }
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if let testResult {
          Text(testResult.success ? "✅ 测试成功" : "❌ \(testResult.detail)")
            .font(.caption)
            .foregroundStyle(testResult.success ? Color.green : .red)
            .lineLimit(2)
        }
      }
      Spacer()
      Button {
        Task {
          testing = true
          testResult = await model.queue.test(channel: channel)
          testing = false
        }
      } label: {
        if testing {
          ProgressView().controlSize(.small)
        } else {
          Text("发送测试")
        }
      }
      .controlSize(.small)
      .disabled(testing)
    }
    .padding(.vertical, 6)
  }
}

/// 通道编辑表单
struct ChannelEditor: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State var channel: ForwardChannelRecord
  @State private var testResult: ForwardResult?
  @State private var testing = false
  @State private var error: String?

  // Bark 设备 Key：编辑时用多行文本，一行一个
  @State private var barkKeysText = ""
  // Webhook 请求头：编辑时用多行文本，每行「名称: 值」
  @State private var headersText = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(channel.id == nil ? "添加 \(channel.type.title) 通道" : "编辑通道")
        .font(.title3.weight(.semibold))
        .padding(20)

      Form {
        Section {
          TextField("名称", text: $channel.name)
          Toggle("启用", isOn: $channel.enabled)
          TextField(
            "最小推送间隔（秒）", value: $channel.minIntervalSeconds, format: .number)
        }
        switch channel.type {
        case .bark: barkSection
        case .webhook: webhookSection
        default: paramsSection
        }
        if let testResult {
          Section("测试结果") {
            Text(
              testResult.success
                ? "✅ 成功（HTTP \(testResult.httpStatus ?? 0)）"
                : "❌ 失败：\(testResult.detail)"
            )
            .font(.callout)
            .textSelection(.enabled)
          }
        }
        if let error {
          Text(error).foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)

      HStack {
        Button {
          Task {
            testing = true
            testResult = await model.queue.test(channel: assembled())
            testing = false
          }
        } label: {
          if testing { ProgressView().controlSize(.small) } else { Text("发送测试") }
        }
        .disabled(testing)
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("保存") { save() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(20)
    }
    .frame(width: 560, height: 620)
    .onAppear {
      barkKeysText = channel.bark?.deviceKeys.joined(separator: "\n") ?? ""
      headersText = (channel.webhook?.headers ?? [:])
        .sorted { $0.key < $1.key }
        .map { "\($0.key): \($0.value)" }
        .joined(separator: "\n")
    }
  }

  // MARK: Bark 配置

  /// Bark 配置的绑定（为 nil 时自动补默认值）
  private var bark: Binding<BarkConfig> {
    Binding(
      get: { channel.bark ?? BarkConfig() },
      set: { channel.bark = $0 })
  }

  @ViewBuilder private var barkSection: some View {
    Section {
      TextField("服务器", text: bark.server, prompt: Text("https://api.day.app"))
      VStack(alignment: .leading, spacing: 4) {
        Text("设备 Key（一行一个）")
        TextEditor(text: $barkKeysText)
          .font(.body.monospaced())
          .frame(minHeight: 54)
          .scrollContentBackground(.hidden)
      }
    } header: {
      Text("Bark")
    } footer: {
      Text("在 iPhone 的 Bark App 首页复制推送地址，取 api.day.app/ 后面那一段即为 Key。")
        .font(.caption).foregroundStyle(.secondary)
    }
    Section("推送选项") {
      TextField("分组", text: bark.group)
      Picker("级别", selection: bark.level) {
        ForEach(BarkLevel.allCases, id: \.self) { level in
          Text(level.title).tag(level)
        }
      }
      TextField("铃声", text: bark.sound, prompt: Text("留空使用默认"))
      TextField("图标 URL", text: bark.icon, prompt: Text("可选"))
      TextField("点击跳转 URL", text: bark.url, prompt: Text("可选，支持模板变量"))
      Toggle("保存到历史", isOn: bark.isArchive)
      Toggle("识别到验证码时自动复制", isOn: bark.autoCopyCode)
    }
  }

  // MARK: Webhook 配置

  private var webhook: Binding<WebhookConfig> {
    Binding(
      get: { channel.webhook ?? WebhookConfig() },
      set: { channel.webhook = $0 })
  }

  @ViewBuilder private var webhookSection: some View {
    Section("请求") {
      TextField("URL", text: webhook.url, prompt: Text("https://example.com/hook"))
      Picker("方法", selection: webhook.method) {
        ForEach(HTTPMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      Picker("请求体格式", selection: webhook.bodyFormat) {
        Text("JSON").tag(WebhookBodyFormat.json)
        Text("表单").tag(WebhookBodyFormat.form)
        Text("纯文本").tag(WebhookBodyFormat.text)
      }
      TextField("超时（秒）", value: webhook.timeout, format: .number)
    }
    Section {
      TextEditor(text: webhook.bodyTemplate)
        .font(.body.monospaced())
        .frame(minHeight: 140)
        .scrollContentBackground(.hidden)
    } header: {
      Text("请求体模板")
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        Text("JSON 格式下变量值会自动转义；表单格式下自动 URL 编码。另可用 {{title}}、{{body}} 引用规则渲染后的标题与正文。")
          .font(.caption).foregroundStyle(.secondary)
        VariableHelp()
      }
    }
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Text("请求头（每行「名称: 值」）")
        TextEditor(text: $headersText)
          .font(.body.monospaced())
          .frame(minHeight: 54)
          .scrollContentBackground(.hidden)
      }
      SecureField("HMAC 签名密钥（可选）", text: webhook.hmacSecret)
      Toggle("忽略 HTTPS 证书错误", isOn: webhook.ignoreSSLErrors)
    } header: {
      Text("高级")
    } footer: {
      Text("设置签名密钥后，请求会附带 X-Timestamp 与 X-Signature: sha256=HMAC(时间戳 + 换行 + 请求体)。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  // MARK: 通用参数配置

  /// 某个参数的绑定
  private func param(_ key: String) -> Binding<String> {
    Binding(
      get: { channel.params[key] ?? "" },
      set: { channel.params[key] = $0 })
  }

  @ViewBuilder private var paramsSection: some View {
    Section {
      ForEach(ChannelCatalog.fields(for: channel.type)) { field in
        VStack(alignment: .leading, spacing: 4) {
          Text(field.required ? "\(field.label) *" : field.label)
            .font(.callout)
          if field.secure {
            SecureField("", text: param(field.key), prompt: Text(field.placeholder))
              .labelsHidden()
          } else {
            TextField("", text: param(field.key), prompt: Text(field.placeholder))
              .labelsHidden()
          }
        }
      }
    } header: {
      Text(channel.type.title)
    } footer: {
      Text(ChannelCatalog.help(for: channel.type))
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  // MARK: 保存

  /// 把多行文本字段合并回配置
  private func assembled() -> ForwardChannelRecord {
    var record = channel
    switch record.type {
    case .bark:
      var config = record.bark ?? BarkConfig()
      config.deviceKeys = barkKeysText
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      record.bark = config
    case .webhook:
      var config = record.webhook ?? WebhookConfig()
      var headers: [String: String] = [:]
      for line in headersText.split(whereSeparator: \.isNewline) {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { headers[key] = value }
      }
      config.headers = headers
      record.webhook = config
    default:
      // 去掉参数首尾空白
      record.params = record.params.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    return record
  }

  private func save() {
    var record = assembled()
    do {
      try model.database.writer.write { db in try record.save(db) }
      dismiss()
    } catch {
      self.error = "保存失败：\(error.localizedDescription)"
    }
  }
}
