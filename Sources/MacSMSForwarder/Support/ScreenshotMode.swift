import AppKit
import ForwarderCore
import Foundation
import GRDB

/// 截图模式：为 README 生成功能截图
///
/// 用法：`scripts/screenshots.sh`（内部以环境变量 MSF_SCREENSHOT_DIR=<输出目录> 启动 App）
/// - 使用内存数据库 + 演示数据，不读写用户的真实数据，不启动收发服务
/// - 设置项使用临时的「参数域」覆盖，不会写入用户的偏好设置
/// - 依次切换到各个页面，截取 App 自己的窗口（截取自身窗口不需要「屏幕录制」权限），完成后自动退出
enum ScreenshotMode {
  /// 截图输出目录；为 nil 表示普通运行
  static let outputDirectory: URL? = ProcessInfo.processInfo.environment["MSF_SCREENSHOT_DIR"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }

  static var isActive: Bool { outputDirectory != nil }

  /// 需要截图的页面及输出文件名
  static let pages: [(SidebarItem, String)] = [
    (.overview, "overview"),
    (.messages, "messages"),
    (.rules, "rules"),
    (.channels, "channels"),
    (.logs, "logs"),
    (.api, "api"),
    (.settings, "settings"),
  ]

  /// 用临时参数域覆盖设置（优先级最高且不持久化），让截图中的开关状态固定
  static func overrideDefaults() {
    UserDefaults.standard.setVolatileDomain(
      [
        SettingsKey.apiEnabled: true,
        SettingsKey.apiPort: 5800,
        SettingsKey.apiLAN: false,
        SettingsKey.preventSleep: true,
        SettingsKey.paused: false,
        SettingsKey.receiveEnabled: true,
        SettingsKey.sendEnabled: true,
        SettingsKey.hideDockIcon: false,
        SettingsKey.autoCheckUpdates: true,
        SettingsKey.retentionDays: 90,
        SettingsKey.region: "CN",
      ], forName: UserDefaults.argumentDomain)
  }

  // MARK: - 演示数据

  /// 写入演示数据：通道、规则、消息、转发日志、API 令牌（号码均为虚构）
  static func seed(_ database: AppDatabase) throws {
    try database.write { db in
      let now = Date()
      func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

      // 通道
      var bark = ForwardChannelRecord(
        type: .bark, name: "我的 iPhone",
        bark: BarkConfig(deviceKeys: ["xxxxxxxxxxxxxxxxxxxx"]))
      var wecom = ForwardChannelRecord(
        type: .wecom, name: "企业微信 · 运维群", params: ["key": "demo"])
      var telegram = ForwardChannelRecord(
        type: .telegram, name: "Telegram 通知",
        params: ["botToken": "demo", "chatID": "-1001234567890", "server": "https://api.telegram.org"])
      var webhook = ForwardChannelRecord(
        type: .webhook, name: "n8n 自动化",
        webhook: WebhookConfig(url: "http://192.168.1.10:5678/webhook/sms"))
      try bark.insert(db)
      try wecom.insert(db)
      try telegram.insert(db)
      try webhook.insert(db)

      // 规则
      var codeRule = ForwardRule(
        name: "验证码推送到手机", priority: 10, matchMode: .any,
        conditions: [
          RuleCondition(field: .text, op: .contains, value: "验证码"),
          RuleCondition(field: .text, op: .regex, value: "(?i)code"),
        ],
        channelIDs: [bark.id!], titleTemplate: "验证码 {{code}}", bodyTemplate: "{{from}}：{{text}}",
        stopAfterMatch: true)
      var bankRule = ForwardRule(
        name: "银行通知到运维群", priority: 20,
        conditions: [RuleCondition(field: .sender, op: .equals, value: "95588")],
        channelIDs: [wecom.id!, telegram.id!])
      var allRule = ForwardRule(
        name: "其余消息交给 n8n", priority: 100,
        conditions: [RuleCondition(field: .isGroup, op: .isFalse)],
        channelIDs: [webhook.id!])
      try codeRule.insert(db)
      try bankRule.insert(db)
      try allRule.insert(db)

      // 消息
      let samples: [(MessageDirection, String, String, String, Double, SendState)] = [
        (.incoming, "SMS", "106900000001", "【某某银行】您的验证码为 482913，5 分钟内有效，请勿泄露。", 2, .none),
        (.incoming, "iMessage", "+8613800138000", "晚上一起吃饭吗？", 8, .none),
        (.outgoing, "iMessage", "+8613800138000", "好的，7 点见", 7, .delivered),
        (.incoming, "SMS", "95588", "【工商银行】您尾号 1234 的账户 10 月 11 日入账 5,000.00 元。", 35, .none),
        (.incoming, "SMS", "10690000002", "Your verification code is 7781. Do not share it.", 62, .none),
        (.outgoing, "iMessage", "alice@example.com", "服务器告警：磁盘使用率 91%", 90, .sent),
        (.incoming, "SMS", "1065000003", "【某某快递】您的包裹已到达小区驿站，取件码 3-2-1024。", 140, .none),
      ]
      var messageIDs: [Int64] = []
      for (i, s) in samples.enumerated() {
        var m = StoredMessage(
          chatdbRowID: Int64(1000 + i), direction: s.0, service: s.1, handle: s.2, chatID: Int64(i),
          text: s.3, date: ago(s.4), sendState: s.5, source: s.0 == .outgoing ? .api : .watcher)
        try m.insert(db)
        messageIDs.append(m.id!)
      }

      // 转发日志
      let logs: [(Int64, String, Bool, Int?, String, String, Int, Double)] = [
        (bark.id!, bark.name, true, 200, "success", "验证码 482913", 312, 2),
        (webhook.id!, webhook.name, true, 200, "{\"ok\":true}", "+8613800138000", 45, 8),
        (wecom.id!, wecom.name, true, 200, "ok", "95588", 268, 35),
        (telegram.id!, telegram.name, false, nil, "The request timed out.", "95588", 15000, 35),
        (telegram.id!, telegram.name, true, 200, "ok", "95588", 820, 33),
        (bark.id!, bark.name, true, 200, "success", "验证码 7781", 290, 62),
      ]
      for l in logs {
        var log = ForwardLog(
          jobID: nil, channelID: l.0, channelName: l.1, success: l.2, httpStatus: l.3,
          detail: l.4, durationMs: l.6, title: l.5, createdAt: ago(l.7))
        try log.insert(db)
      }

      // API 令牌（仅展示用，不是真实令牌）
      var token = APIToken(
        name: "n8n", tokenHash: TokenManager.hash("demo-n8n"), prefix: "msf_Xk3pQ",
        lastUsedAt: ago(5))
      var shortcut = APIToken(
        name: "快捷指令", tokenHash: TokenManager.hash("demo-shortcut"), prefix: "msf_9fLwA")
      try token.insert(db)
      try shortcut.insert(db)
    }
  }

  // MARK: - 截图

  /// 依次切换页面并截取主窗口，完成后退出
  @MainActor
  static func run(model: AppModel) {
    guard let directory = outputDirectory else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    Task { @MainActor in
      // 等待主窗口出现并完成首次布局
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else {
        print("截图失败：找不到主窗口")
        NSApp.terminate(nil)
        return
      }
      // 固定窗口尺寸与浅色外观，保证每张截图一致
      NSApp.appearance = NSAppearance(named: .aqua)
      window.appearance = NSAppearance(named: .aqua)
      window.setContentSize(NSSize(width: 1000, height: 640))
      window.center()
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)

      for (page, name) in pages {
        model.requestedPage = page
        // 等待页面切换、数据库观察器回调与动画完成
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let url = directory.appendingPathComponent("\(name).png")
        if capture(window, to: url) {
          print("已生成 \(url.path)")
        } else {
          print("截图失败：\(name)")
        }
      }
      NSApp.terminate(nil)
    }
  }

  /// CGWindowListCreateImage 的函数指针
  /// 该函数在 macOS 14 起标记为废弃（推荐 ScreenCaptureKit，但 ScreenCaptureKit 需要「屏幕录制」权限），
  /// 截取本 App 自己的窗口用它最简单且无需授权；通过动态查找调用以避免编译警告，仅截图模式使用
  private typealias WindowImageFn = @convention(c) (
    CGRect, UInt32, CGWindowID, UInt32
  ) -> Unmanaged<CGImage>?
  private static let windowListCreateImage: WindowImageFn = {
    let handle = dlopen(nil, RTLD_NOW)
    let symbol = dlsym(handle, "CGWindowListCreateImage")
    return unsafeBitCast(symbol, to: WindowImageFn.self)
  }()

  /// 截取指定窗口（不含阴影）并保存为 PNG
  @MainActor
  private static func capture(_ window: NSWindow, to url: URL) -> Bool {
    guard
      let image = windowListCreateImage(
        .null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber),
        CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue)?
        .takeRetainedValue()
    else { return false }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: url)) != nil
  }
}
