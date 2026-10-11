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
  /// 数据库打开失败时的错误（极少发生）
  @Published var fatalError: String?

  private let defaults = UserDefaults.standard
  private var statsObservation: AnyDatabaseCancellable?
  private var permissionTimer: Timer?

  private init() {
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
    ])

    // 打开数据库；失败时退回内存数据库，保证界面可用并提示错误
    var openError: String?
    let db: AppDatabase
    do {
      db = try AppDatabase.openDefault()
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
