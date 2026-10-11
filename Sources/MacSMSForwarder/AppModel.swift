import AppKit
import ForwarderCore
import Foundation
import GRDB
import SwiftUI

/// 设置项的 UserDefaults 键名
enum SettingsKey {
  static let apiEnabled = "apiEnabled"
  static let apiPort = "apiPort"
  static let apiLAN = "apiLAN"
  static let preventSleep = "preventSleep"
  static let forwardOutgoing = "forwardOutgoing"
  static let allowSMSFallback = "allowSMSFallback"
  static let retentionDays = "retentionDays"
  static let paused = "paused"
  static let region = "region"
  static let hideDockIcon = "hideDockIcon"
  /// 功能开关：接收并转发
  static let receiveEnabled = "receiveEnabled"
  /// 功能开关：发送（界面与 API）
  static let sendEnabled = "sendEnabled"
  /// 启动时自动检查更新
  static let autoCheckUpdates = "autoCheckUpdates"
  /// 用户选择「跳过」的版本（自动检查时不再提示该版本）
  static let skippedVersion = "skippedVersion"
}

/// 全局应用状态：持有所有服务，负责启动、停止和状态汇总
@MainActor
final class AppModel: ObservableObject {
  static let shared = AppModel()

  // MARK: 服务
  let database: AppDatabase
  let events = EventBus()
  let queue: ForwardQueue
  let ingest: IngestService
  let sendService: SendService
  private let sleepGuard = SleepGuard()
  private var server: HTTPServer?

  // MARK: 界面状态
  @Published var ingestStatus: IngestStatus = .stopped
  @Published var fullDiskAccess: PermissionState = .unknown
  @Published var automation: PermissionState = .unknown
  @Published var messagesRunning = false
  @Published var serverError: String?
  @Published var serverRunning = false
  @Published var paused: Bool
  /// 接收转发功能是否开启（关闭后停止监听 chat.db，不需要「完全磁盘访问」权限）
  @Published private(set) var receiveEnabled: Bool
  /// 发送功能是否开启（关闭后界面与 API 都不能发送，不需要「自动化」权限）
  @Published private(set) var sendEnabled: Bool
  @Published var todayReceived = 0
  @Published var todayForwarded = 0
  /// 截图模式下由程序切换的页面（RootView 监听它来切换侧栏选中项）
  @Published var requestedPage: SidebarItem?
  /// 正在检查更新
  @Published var checkingUpdate = false
  /// 最近一次检查更新的结果说明（显示在「关于」中）
  @Published var updateStatus: String?
  /// 数据库打开失败时的错误（极少发生）
  @Published var fatalError: String?

  private let defaults = UserDefaults.standard
  private var statsObservation: AnyDatabaseCancellable?
  private var permissionTimer: Timer?

  private init() {
    // 截图模式：用临时参数域固定设置，不写入用户偏好
    if ScreenshotMode.isActive { ScreenshotMode.overrideDefaults() }

    // 注册设置默认值
    UserDefaults.standard.register(defaults: [
      SettingsKey.apiEnabled: false,
      SettingsKey.apiPort: 5800,
      SettingsKey.apiLAN: false,
      SettingsKey.preventSleep: true,
      SettingsKey.forwardOutgoing: false,
      SettingsKey.allowSMSFallback: true,
      SettingsKey.retentionDays: 90,
      SettingsKey.paused: false,
      SettingsKey.region: Locale.current.region?.identifier ?? "CN",
      SettingsKey.hideDockIcon: false,
      SettingsKey.receiveEnabled: true,
      SettingsKey.sendEnabled: true,
      SettingsKey.autoCheckUpdates: true,
    ])

    // 打开数据库；失败时退回内存数据库，保证界面可用并提示错误
    var openError: String?
    let db: AppDatabase
    do {
      if ScreenshotMode.isActive {
        // 截图模式：内存数据库 + 演示数据，不触碰真实数据
        let demo = try AppDatabase.inMemory()
        try ScreenshotMode.seed(demo)
        db = demo
      } else {
        db = try AppDatabase.openDefault()
      }
    } catch {
      openError = "数据库打开失败：\(error.localizedDescription)"
      db = try! AppDatabase.inMemory()
    }
    database = db
    queue = ForwardQueue(database: db, events: events)
    ingest = IngestService(database: db, queue: queue, events: events)
    sendService = SendService(
      database: db, events: events,
      region: UserDefaults.standard.string(forKey: SettingsKey.region) ?? "CN",
      allowSMSFallback: UserDefaults.standard.bool(forKey: SettingsKey.allowSMSFallback))
    paused = UserDefaults.standard.bool(forKey: SettingsKey.paused)
    receiveEnabled = UserDefaults.standard.bool(forKey: SettingsKey.receiveEnabled)
    sendEnabled = UserDefaults.standard.bool(forKey: SettingsKey.sendEnabled)
    sendService.isEnabled = sendEnabled
    fatalError = openError
  }

  // MARK: - 启动

  /// App 启动后调用一次
  func start() {
    // 截图模式：只展示界面，不启动任何服务
    if ScreenshotMode.isActive {
      ingestStatus = .running
      fullDiskAccess = .granted
      automation = .granted
      messagesRunning = true
      serverRunning = true
      updateStatus = "已是最新版本"
      observeStats()
      ScreenshotMode.run(model: self)
      return
    }

    refreshPermissions()
    // 「信息」未运行时在后台启动它（发送和自动化授权都需要它在运行）
    if !Permissions.isMessagesRunning {
      Permissions.launchMessagesInBackground()
    }

    Task {
      await ingest.onStatusChange { status in
        Task { @MainActor in AppModel.shared.ingestStatus = status }
      }
      await ingest.setForwardOutgoing(defaults.bool(forKey: SettingsKey.forwardOutgoing))
      await queue.setPaused(paused)
      await queue.start()
      // 只有开启了接收转发才监听 chat.db
      if receiveEnabled { await ingest.start() }
    }

    applyDockIcon()
    applySleepGuard()
    applyServer()
    observeStats()
    try? database.purge(olderThanDays: defaults.integer(forKey: SettingsKey.retentionDays))

    // 启动 5 秒后静默检查更新（只在发现新版本时弹窗）
    if defaults.bool(forKey: SettingsKey.autoCheckUpdates) {
      Task {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        checkForUpdates(userInitiated: false)
      }
    }

    // 每 5 秒刷新一次权限状态（用户可能在系统设置里刚刚授权）
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
      Task { @MainActor in AppModel.shared.refreshPermissions() }
    }
  }

  /// 刷新权限状态；完全磁盘访问刚被授予时立即重启收信
  func refreshPermissions() {
    let previous = fullDiskAccess
    fullDiskAccess = Permissions.fullDiskAccess()
    automation = Permissions.automation(ask: false)
    messagesRunning = Permissions.isMessagesRunning
    if receiveEnabled, previous != .granted, fullDiskAccess == .granted, ingestStatus != .running {
      Task { await ingest.restart() }
    }
  }

  /// 请求自动化权限（会弹出系统授权框）
  func requestAutomation() {
    if !Permissions.isMessagesRunning { Permissions.launchMessagesInBackground() }
    // 在后台线程请求，避免授权框阻塞主线程
    DispatchQueue.global().async {
      _ = Permissions.automation(ask: true)
      Task { @MainActor in AppModel.shared.refreshPermissions() }
    }
  }

  // MARK: - 版本更新

  /// 检查更新
  /// - Parameter userInitiated: 用户手动点击时为 true：无论结果如何都给出反馈，且不受「跳过此版本」影响
  func checkForUpdates(userInitiated: Bool) {
    guard !checkingUpdate else { return }
    checkingUpdate = true
    if userInitiated { updateStatus = nil }
    let current = Bundle.main.shortVersion
    Task {
      let result = await UpdateChecker.check(currentVersion: current)
      checkingUpdate = false
      switch result {
      case .available(let release):
        updateStatus = "发现新版本 v\(release.version)"
        let skipped = defaults.string(forKey: SettingsKey.skippedVersion)
        if userInitiated || skipped != release.version {
          presentUpdateAlert(release, current: current)
        }
      case .upToDate(let latest):
        updateStatus = "已是最新版本（GitHub 最新为 v\(latest)）"
      case .failed(let reason):
        // 自动检查失败时保持安静，只在手动检查时显示原因
        if userInitiated { updateStatus = "检查失败：\(reason)" }
      }
    }
  }

  /// 弹窗提示新版本；确认后在浏览器中打开发布页
  private func presentUpdateAlert(_ release: ReleaseInfo, current: String) {
    // 隐藏程序坞图标时 App 不在前台，先激活以确保弹窗可见
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "发现新版本 v\(release.version)"
    // 更新说明过长时截断，完整内容在发布页查看
    let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = notes.count > 600 ? String(notes.prefix(600)) + "…" : notes
    alert.informativeText =
      "当前版本 v\(current)，是否前往 GitHub 下载新版本？" + (preview.isEmpty ? "" : "\n\n\(preview)")
    alert.alertStyle = .informational
    alert.addButton(withTitle: "前往下载")
    alert.addButton(withTitle: "以后再说")
    alert.addButton(withTitle: "跳过此版本")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      NSWorkspace.shared.open(release.pageURL)
    case .alertThirdButtonReturn:
      defaults.set(release.version, forKey: SettingsKey.skippedVersion)
    default:
      break
    }
  }

  // MARK: - 设置应用

  /// 开启或关闭「接收转发」：关闭时停止监听，开启时从上次位置继续
  func setReceiveEnabled(_ value: Bool) {
    receiveEnabled = value
    defaults.set(value, forKey: SettingsKey.receiveEnabled)
    Task {
      if value {
        // 重新开启时从「现在」开始接收，不补发关闭期间的消息
        try? database.removeSyncValue(AppDatabase.lastRowIDKey)
        await ingest.start()
      } else {
        await ingest.stop()
      }
    }
  }

  /// 开启或关闭「发送」
  func setSendEnabled(_ value: Bool) {
    sendEnabled = value
    defaults.set(value, forKey: SettingsKey.sendEnabled)
    sendService.isEnabled = value
  }

  func setPaused(_ value: Bool) {
    paused = value
    defaults.set(value, forKey: SettingsKey.paused)
    Task { await queue.setPaused(value) }
  }

  /// 显示或隐藏程序坞图标
  /// 隐藏后 App 只保留菜单栏图标（accessory 模式），主窗口仍可从菜单栏打开
  func applyDockIcon() {
    let hide = defaults.bool(forKey: SettingsKey.hideDockIcon)
    let policy: NSApplication.ActivationPolicy = hide ? .accessory : .regular
    guard NSApp.activationPolicy() != policy else { return }
    NSApp.setActivationPolicy(policy)
    // 切换策略后窗口可能失去焦点，重新激活以保持主窗口在前
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      for window in NSApp.windows where window.canBecomeMain && window.isVisible {
        window.makeKeyAndOrderFront(nil)
      }
    }
  }

  func applySleepGuard() {
    sleepGuard.set(defaults.bool(forKey: SettingsKey.preventSleep))
  }

  func applyForwardOutgoing() {
    let value = defaults.bool(forKey: SettingsKey.forwardOutgoing)
    Task { await ingest.setForwardOutgoing(value) }
  }

  func applySendOptions() {
    sendService.allowSMSFallback = defaults.bool(forKey: SettingsKey.allowSMSFallback)
    sendService.region = defaults.string(forKey: SettingsKey.region) ?? "CN"
  }

  /// 根据设置启动或停止 HTTP API
  func applyServer() {
    server?.stop()
    server = nil
    serverRunning = false
    serverError = nil
    guard defaults.bool(forKey: SettingsKey.apiEnabled) else { return }

    let port = defaults.integer(forKey: SettingsKey.apiPort)
    let router = APIRouter(
      database: database, sendService: sendService, events: events,
      ingestStatus: { [ingest] in await ingest.status })
    let server = HTTPServer { request in await router.handle(request) }
    do {
      try server.start(
        port: UInt16(clamping: port), localOnly: !defaults.bool(forKey: SettingsKey.apiLAN))
      self.server = server
      serverRunning = true
    } catch {
      serverError = error.localizedDescription
    }
  }

  // MARK: - 统计

  /// 观察今日收信数与转发成功数，用于概览和菜单栏
  private func observeStats() {
    let observation = ValueObservation.tracking { db -> (Int, Int) in
      let start = Calendar.current.startOfDay(for: Date())
      let received = try StoredMessage
        .filter(Column("direction") == MessageDirection.incoming.rawValue)
        .filter(Column("date") >= start)
        .fetchCount(db)
      let forwarded = try ForwardLog
        .filter(Column("success") == true)
        .filter(Column("createdAt") >= start)
        .fetchCount(db)
      return (received, forwarded)
    }
    statsObservation = observation.start(
      in: database.writer,
      onError: { _ in },
      onChange: { [weak self] value in
        self?.todayReceived = value.0
        self?.todayForwarded = value.1
      })
  }

  // MARK: - 汇总状态

  /// 整体健康度：用于菜单栏和侧栏的状态灯
  enum Health {
    case ok
    case warning
    case error
  }

  var health: Health {
    // 未开启接收：只发送模式视为正常；两个功能都关闭时提示
    guard receiveEnabled else { return sendEnabled ? .ok : .warning }
    switch ingestStatus {
    case .running:
      return paused ? .warning : .ok
    case .permissionDenied, .error:
      return .error
    case .stopped:
      return .warning
    }
  }

  var healthText: String {
    guard receiveEnabled else { return sendEnabled ? "仅发送模式" : "功能已全部关闭" }
    switch ingestStatus {
    case .running: return paused ? "转发已暂停" : "运行中"
    case .permissionDenied: return "缺少完全磁盘访问权限"
    case .error(let message): return "出错：\(message)"
    case .stopped: return "未启动"
    }
  }
}
