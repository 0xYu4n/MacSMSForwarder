import AppKit
import ForwarderCore
import SwiftUI

/// 设置页
struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @AppStorage(SettingsKey.preventSleep) private var preventSleep = true
  @AppStorage(SettingsKey.forwardOutgoing) private var forwardOutgoing = false
  @AppStorage(SettingsKey.allowSMSFallback) private var allowSMSFallback = true
  @AppStorage(SettingsKey.retentionDays) private var retentionDays = 90
  @AppStorage(SettingsKey.region) private var region = "CN"
  @AppStorage(SettingsKey.hideDockIcon) private var hideDockIcon = false
  @State private var launchAtLogin = LaunchAtLogin.isEnabled
  @State private var launchError: String?

  var body: some View {
    Form {
      Section {
        Toggle(
          isOn: Binding(get: { model.receiveEnabled }, set: { model.setReceiveEnabled($0) })
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("接收转发")
            Text("监听收到的 iMessage / 短信，按规则转发到各通道。需要「完全磁盘访问」权限。")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Toggle(
          isOn: Binding(get: { model.sendEnabled }, set: { model.setSendEnabled($0) })
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("发送")
            Text("允许在界面或通过 HTTP API 发送 iMessage / 短信。需要「自动化 › 信息」权限。")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("功能开关")
      } footer: {
        Text("只需要其中一项功能时，关闭另一项即可，对应的权限也无需授予。重新开启接收时，从开启那一刻起接收，不补发关闭期间的消息。")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("通用") {
        Toggle("开机自动启动", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, value in
            do {
              try LaunchAtLogin.set(value)
              launchError = nil
            } catch {
              launchError = error.localizedDescription
              launchAtLogin = LaunchAtLogin.isEnabled
            }
          }
        if let launchError {
          Text(launchError).font(.caption).foregroundStyle(.red)
        }
        Toggle("隐藏程序坞图标", isOn: $hideDockIcon)
          .onChange(of: hideDockIcon) { _, _ in model.applyDockIcon() }
        Text("隐藏后只在菜单栏显示图标，从菜单栏可随时打开主窗口。")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("阻止系统休眠", isOn: $preventSleep)
          .onChange(of: preventSleep) { _, _ in model.applySleepGuard() }
        Text("休眠后无法收发消息。开启后显示器仍可正常关闭。")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("转发") {
        Toggle(
          "暂停推送（继续接收，恢复后补推）",
          isOn: Binding(get: { model.paused }, set: { model.setPaused($0) }))
        Toggle("同时转发自己发出的消息", isOn: $forwardOutgoing)
          .onChange(of: forwardOutgoing) { _, _ in model.applyForwardOutgoing() }
        Text("默认关闭，避免「转发到 iMessage」时形成循环。")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("发送") {
        Toggle("iMessage 失败时退回短信", isOn: $allowSMSFallback)
          .onChange(of: allowSMSFallback) { _, _ in model.applySendOptions() }
        Text("需要在 iPhone「设置 › 信息 › 短信转发」中勾选这台 Mac。")
          .font(.caption).foregroundStyle(.secondary)
        Picker("号码默认地区", selection: $region) {
          Text("中国大陆（+86）").tag("CN")
          Text("中国香港（+852）").tag("HK")
          Text("中国台湾（+886）").tag("TW")
          Text("美国（+1）").tag("US")
          Text("日本（+81）").tag("JP")
        }
        .onChange(of: region) { _, _ in model.applySendOptions() }
      }

      Section("数据") {
        Picker("消息与日志保留", selection: $retentionDays) {
          Text("7 天").tag(7)
          Text("30 天").tag(30)
          Text("90 天").tag(90)
          Text("1 年").tag(365)
          Text("永久").tag(0)
        }
        .onChange(of: retentionDays) { _, value in
          try? model.database.purge(olderThanDays: value)
        }
        Button("在访达中显示数据目录") {
          if let url = try? AppDatabase.defaultURL() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        }
      }

      Section("关于") {
        LabeledContent("版本", value: Bundle.main.shortVersion)
        LabeledContent("本机名称", value: RuleEngine.deviceName)
        Link("GitHub 开源主页", destination: URL(string: "https://github.com/0xYu4n/MacSMSForwarder")!)
        Text("Mac短信转发与 Apple 无任何关联。请勿用于群发或骚扰信息，以免 Apple ID 被限制。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("设置")
  }
}

extension Bundle {
  /// 版本号（例如 0.1.0）
  var shortVersion: String {
    (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "开发版"
  }
}
