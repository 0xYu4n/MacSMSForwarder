import Foundation
import GRDB
import IMsgCore

/// 收信服务的运行状态
public enum IngestStatus: Equatable, Sendable {
  case stopped
  case running
  /// 无法读取 chat.db（通常是缺少「完全磁盘访问」权限）
  case permissionDenied
  case error(String)
}

/// 收信服务：监听 chat.db 新消息 → 去重写入自有库 → 规则匹配 → 生成转发任务
public actor IngestService {
  private let database: AppDatabase
  private let queue: ForwardQueue
  private let events: EventBus
  /// chat.db 路径（测试时可指向副本）
  private let chatDBPath: String

  private var task: Task<Void, Never>?
  /// 群聊判断缓存：chatID → 是否群聊
  private var groupCache: [Int64: Bool] = [:]
  /// 是否转发自己发出的消息（默认否，防止转发死循环）
  public var forwardOutgoing = false

  /// 状态变化回调（界面用来刷新状态指示灯）
  private var statusHandler: (@Sendable (IngestStatus) -> Void)?
  public private(set) var status: IngestStatus = .stopped {
    didSet { statusHandler?(status) }
  }

  public init(
    database: AppDatabase,
    queue: ForwardQueue,
    events: EventBus,
    chatDBPath: String = MessageStore.defaultPath
  ) {
    self.database = database
    self.queue = queue
    self.events = events
    self.chatDBPath = chatDBPath
  }

  public func onStatusChange(_ handler: @escaping @Sendable (IngestStatus) -> Void) {
    statusHandler = handler
    handler(status)
  }

  public func setForwardOutgoing(_ value: Bool) {
    forwardOutgoing = value
  }

  // MARK: - 启停

  /// 启动监听；出错后每 10 秒自动重试（例如用户稍后才授予权限）
  public func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.runOnce()
        if Task.isCancelled { break }
        try? await Task.sleep(nanoseconds: 10_000_000_000)
      }
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
    status = .stopped
  }

  /// 立即重启（用户刚授予权限时调用）
  public func restart() {
    stop()
    start()
  }

  /// 打开 chat.db 并持续消费新消息，直到出错或被取消
  private func runOnce() async {
    let store: MessageStore
    do {
      store = try MessageStore(path: chatDBPath)
    } catch {
      status = Self.isPermissionError(error) ? .permissionDenied : .error(error.localizedDescription)
      return
    }

    // 首次运行：从当前最大 ROWID 开始，不转发历史消息
    var cursor: Int64
    do {
      if let saved = try database.syncValue(AppDatabase.lastRowIDKey), let value = Int64(saved) {
        cursor = value
      } else {
        cursor = try store.maxRowID()
        try database.setSyncValue(AppDatabase.lastRowIDKey, String(cursor))
      }
    } catch {
      status = .error(error.localizedDescription)
      return
    }

    status = .running
    let watcher = MessageWatcher(store: store)
    // 溢出时从 resumeAfterRowID 继续，循环直到被取消
    while !Task.isCancelled {
      do {
        for try await message in watcher.stream(sinceRowID: cursor) {
          if Task.isCancelled { return }
          await handle(message, store: store)
          cursor = max(cursor, message.rowID)
          try? database.setSyncValue(AppDatabase.lastRowIDKey, String(cursor))
        }
        // 流正常结束（一般不会发生），稍后重开
        return
      } catch let overflow as MessageWatcherOverflowError {
        // 缓冲区溢出：从上游告知的位置继续，不丢消息
        cursor = overflow.resumeAfterRowID
        continue
      } catch {
        status = Self.isPermissionError(error) ? .permissionDenied : .error(error.localizedDescription)
        return
      }
    }
  }

  // MARK: - 处理单条消息

  /// 处理 chat.db 中的一条新消息
  func handle(_ message: Message, store: MessageStore) async {
    // 表情回应（tapback）不入库、不转发
    if message.isReaction { return }

    let isGroup = groupFlag(chatID: message.chatID, store: store)
    var record = StoredMessage(
      chatdbRowID: message.rowID,
      guid: message.guid.isEmpty ? nil : message.guid,
      direction: message.isFromMe ? .outgoing : .incoming,
      service: message.service.isEmpty ? "iMessage" : message.service,
      handle: message.sender,
      chatID: message.chatID,
      isGroup: isGroup,
      text: message.text,
      attachmentsCount: message.attachmentsCount,
      date: message.date,
      sendState: message.isFromMe ? .sent : .none,
      source: .watcher
    )

    // 写入自有库：按 chatdbRowID 去重；自己发出的消息若能匹配到 API 发送的待定记录则合并
    let inserted: Bool
    do {
      inserted = try database.write { db -> Bool in
        if try StoredMessage.filter(Column("chatdbRowID") == message.rowID).fetchCount(db) > 0 {
          return false
        }
        if message.isFromMe, var pending = try Self.findPendingOutgoing(db, text: message.text) {
          // 由 API/界面发出、尚未关联 chat.db 的记录：补全信息，不新增
          pending.chatdbRowID = message.rowID
          pending.guid = record.guid
          pending.chatID = message.chatID
          pending.service = record.service
          pending.isGroup = isGroup
          if pending.sendState == .pending { pending.sendState = .sent }
          try pending.update(db)
          record = pending
          return false
        }
        try record.insert(db)
        return true
      }
    } catch {
      return
    }
    guard inserted else { return }
    events.publish(.message(record))

    // 只转发收到的消息（除非用户在设置中开启了转发发出的消息）
    guard record.direction == .incoming || forwardOutgoing else { return }
    do {
      let rules = try database.read { db in
        try ForwardRule.filter(Column("enabled") == true).fetchAll(db)
      }
      let matched = RuleEngine.matchingRules(for: record, rules: rules)
      if !matched.isEmpty {
        try await queue.enqueue(message: record, rules: matched)
      }
    } catch {
      // 规则读取失败不影响后续消息
    }
  }

  /// 查找最近 5 分钟内、正文相同、尚未关联 chat.db 的发出记录
  static func findPendingOutgoing(_ db: Database, text: String) throws -> StoredMessage? {
    try StoredMessage
      .filter(Column("direction") == MessageDirection.outgoing.rawValue)
      .filter(Column("chatdbRowID") == nil)
      .filter(Column("text") == text)
      .filter(Column("date") > Date().addingTimeInterval(-300))
      .order(Column("id"))
      .fetchOne(db)
  }

  /// 判断会话是否为群聊（chat.db 中群聊的 identifier 以 "chat" 开头）
  private func groupFlag(chatID: Int64, store: MessageStore) -> Bool {
    if let cached = groupCache[chatID] { return cached }
    let info = try? store.chatInfo(chatID: chatID)
    let value = info?.identifier.hasPrefix("chat") ?? false
    groupCache[chatID] = value
    return value
  }

  /// 判断错误是否为权限不足
  static func isPermissionError(_ error: Error) -> Bool {
    if case IMsgError.permissionDenied = error { return true }
    let text = String(describing: error).lowercased()
    return text.contains("authorization denied") || text.contains("permission")
      || text.contains("operation not permitted")
  }
}
