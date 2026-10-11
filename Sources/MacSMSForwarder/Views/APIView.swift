import AppKit
import ForwarderCore
import GRDB
import SwiftUI

/// HTTP API 页：开关、端口、令牌管理、调用示例
struct APIView: View {
  @EnvironmentObject private var model: AppModel
  @AppStorage(SettingsKey.apiEnabled) private var enabled = false
  @AppStorage(SettingsKey.apiPort) private var port = 5800
  @AppStorage(SettingsKey.apiLAN) private var lan = false

  @State private var newTokenName = ""
  /// 刚创建的令牌明文（只显示一次）
  @State private var createdToken: String?

  @StateObject private var tokens = DBObserver<[APIToken]>(initial: []) { db in
    try APIToken.order(Column("id")).fetchAll(db)
  }

  private var baseURL: String {
    "http://\(lan ? "<本机IP>" : "127.0.0.1"):\(port)"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        PageHeader(title: "HTTP API", subtitle: "供 n8n、快捷指令、脚本等自动化工具调用，发送 iMessage 与查询消息")

        // 服务开关
        Card {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("API 服务").font(.headline)
              HStack(spacing: 6) {
                StatusDot(color: model.serverRunning ? .green : .secondary)
                Text(model.serverRunning ? "监听于 \(baseURL)" : "未启动")
                  .font(.callout).foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
              if let error = model.serverError {
                Text("启动失败：\(error)").font(.caption).foregroundStyle(.red)
              }
            }
            Spacer()
            Toggle("", isOn: $enabled)
              .toggleStyle(.switch)
              .labelsHidden()
              .onChange(of: enabled) { _, _ in model.applyServer() }
          }
          Divider()
          HStack {
            Text("端口")
            TextField("", value: $port, format: .number.grouping(.never))
              .frame(width: 80)
              .onSubmit { model.applyServer() }
            Spacer()
            Toggle("允许局域网访问", isOn: $lan)
              .onChange(of: lan) { _, _ in model.applyServer() }
          }
          if lan {
            Text("⚠️ 开启后同一网络中的设备都能访问此接口，请妥善保管 Token。")
              .font(.caption).foregroundStyle(.orange)
          }
        }

        // 令牌管理
        Card {
          Text("访问令牌").font(.headline)
          if let createdToken {
            VStack(alignment: .leading, spacing: 6) {
              Text("新令牌已创建，请立即复制，关闭后将无法再次查看：")
                .font(.caption).foregroundStyle(.orange)
              HStack {
                Text(createdToken)
                  .font(.callout.monospaced())
                  .textSelection(.enabled)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Spacer()
                Button("复制") { copy(createdToken) }
                Button("完成") { self.createdToken = nil }
              }
              .padding(10)
              .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
            }
          }
          ForEach(tokens.value) { token in
            HStack {
              Image(systemName: "key").foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(token.name).font(.body.weight(.medium))
                Text(
                  "\(token.prefix)…  ·  最近使用：\(token.lastUsedAt.map(DateText.short) ?? "从未")"
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
              }
              Spacer()
              Button(role: .destructive) {
                _ = try? model.database.writer.write { db in try token.delete(db) }
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
            }
          }
          HStack {
            TextField("令牌名称，例如 n8n", text: $newTokenName)
            Button("创建令牌") {
              let name = newTokenName.trimmingCharacters(in: .whitespaces)
              if let result = try? TokenManager.create(
                name: name.isEmpty ? "未命名" : name, canSend: true, canRead: true,
                in: model.database)
              {
                createdToken = result.plain
                newTokenName = ""
              }
            }
          }
        }

        // 调用示例
        Card {
          Text("调用示例").font(.headline)
          CodeBlock(
            title: "发送 iMessage",
            code: """
              curl -X POST \(baseURL)/api/v1/messages/send \\
                -H "Authorization: Bearer <TOKEN>" \\
                -H "Content-Type: application/json" \\
                -d '{"to":"+8613800138000","text":"你好","service":"auto"}'
              """)
          CodeBlock(
            title: "查询发送状态",
            code: """
              curl \(baseURL)/api/v1/messages/<ID> -H "Authorization: Bearer <TOKEN>"
              """)
          CodeBlock(
            title: "最近收到的消息",
            code: """
              curl "\(baseURL)/api/v1/messages?direction=incoming&limit=20" \\
                -H "Authorization: Bearer <TOKEN>"
              """)
          CodeBlock(
            title: "实时事件流（SSE）",
            code: """
              curl -N \(baseURL)/api/v1/events -H "Authorization: Bearer <TOKEN>"
              """)
        }
      }
      .padding(24)
    }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// 代码示例块（带复制按钮）
private struct CodeBlock: View {
  var title: String
  var code: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.callout.weight(.medium))
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("复制")
      }
      Text(code)
        .font(.system(size: 11.5, design: .monospaced))
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
  }
}
