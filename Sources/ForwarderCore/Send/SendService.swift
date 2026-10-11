import Foundation
import GRDB
import IMsgCore

/// 发送请求
public struct SendRequest: Codable, Sendable {
  /// 收件人：手机号（建议带国家码，如 +8613800138000）或 Apple ID 邮箱
  public var to: String
  public var text: String
  /// auto / imessage / sms，默认 auto（优先 iMessage，失败时按设置退回短信）
  public var service: String?
  /// 本地附件绝对路径（可选）
  public var attachment: String?

  public init(to: String, text: String, service: String? = nil, attachment: String? = nil) {
    self.to = to
    self.text = text
    self.service = service
    self.attachment = attachment
  }
}

/// 发送错误
public enum SendError: LocalizedError {
  case invalidRecipient
  case emptyMessage
  case invalidService(String)
  case disabled

  public var errorDescription: String? {
    switch self {
    case .disabled: return "发送功能已关闭，请在「设置 › 功能开关」中开启"
    case .invalidRecipient: return "收件人不能为空"
    case .emptyMessage: return "消息内容和附件不能同时为空"
    case .invalidService(let s): return "不支持的服务类型：\(s)，可选 auto / imessage / sms"
    }
  }
}

/// 发送服务：通过 IMsgCore（AppleScript 后台驱动「信息」App）发送，并回查 chat.db 跟踪状态
public final class SendService: @unchecked Sendable {
  private let database: AppDatabase
  private let events: EventBus
  private let chatDBPath: String
  /// 号码规范化使用的默认地区（中国大陆为 CN）
  public var region: String
  /// iMessage 发送失败时是否允许退回短信（需要 iPhone 开启短信转发）
  public var allowSMSFallback: Bool
  /// 发送功能总开关：关闭后界面和 API 都不能发送
  public var isEnabled = true

  /// 串行执行 AppleScript，避免并发驱动「信息」App 导致错乱
  private let sendQueue = DispatchQueue(label: "macsmsforwarder.send")

  public init(
    database: AppDatabase,
    events: EventBus,
    chatDBPath: String = MessageStore.defaultPath,
    region: String = Locale.current.region?.identifier ?? "CN",
    allowSMSFallback: Bool = true
  ) {
    self.database = database
    self.events = events
    self.chatDBPath = chatDBPath
    self.region = region
    self.allowSMSFallback = allowSMSFallback
  }

  /// 发送消息：先写入待发送记录并立即返回，实际发送与状态跟踪在后台完成
  public func send(_ request: SendRequest, source: MessageSource) throws -> StoredMessage {
    guard isEnabled else { throw SendError.disabled }
    let to = request.to.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !to.isEmpty else { throw SendError.invalidRecipient }
    let attachment = request.attachment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !request.text.isEmpty || !attachment.isEmpty else { throw SendError.emptyMessage }
    let serviceName = (request.service ?? "auto").lowercased()
    guard let service = MessageService(rawValue: serviceName) else {
      throw SendError.invalidService(serviceName)
    }

    // 写入待发送记录
    var record = StoredMessage(
      direction: .outgoing,
      service: service == .sms ? "SMS" : "iMessage",
      handle: to,
      text: request.text,
      attachmentsCount: attachment.isEmpty ? 0 : 1,
      date: Date(),
      sendState: .pending,
      source: source
    )
    try database.write { db in try record.insert(db) }
    events.publish(.message(record))

    let options = MessageSendOptions(
      recipient: to,
      text: request.text,
      attachmentPath: attachment,
      service: service,
      region: region,
      allowSMSFallback: allowSMSFallback
    )
    let started = Date()
    let pending = record
    sendQueue.async { [weak self] in
      self?.perform(options: options, record: pending, started: started)
    }
    return record
  }

  /// 在串行队列中执行 AppleScript 发送，然后跟踪状态
  private func perform(options: MessageSendOptions, record: StoredMessage, started: Date) {
    var record = record
    do {
      let resolved = try MessageSender().sendResolvingRoute(options)
      // 记录实际使用的服务（可能已退回短信）
      record.service = resolved.service == .sms ? "SMS" : "iMessage"
      record.handle = resolved.recipient.isEmpty ? record.handle : resolved.recipient
      update(record)
    } catch {
      record.sendState = .failed
      record.errorMessage = error.localizedDescription
      update(record)
      return
    }
    // 后台跟踪送达状态
    Task.detached { [weak self] in
      await self?.track(record: record, started: started)
    }
  }

  /// 轮询 chat.db：先找到对应的消息行，再跟踪 sent → delivered / failed，最长约 2 分钟
  private func track(record: StoredMessage, started: Date) async {
    guard let store = try? MessageStore(path: chatDBPath) else { return }
    var record = record
    let deadline = Date().addingTimeInterval(120)

    while Date() < deadline {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      // 收信服务可能已经把它关联上（补全了 guid），先从自有库刷新
      if let id = record.id,
        let fresh = try? database.read({ db in try StoredMessage.fetchOne(db, key: id) })
      {
        record.guid = fresh.guid ?? record.guid
        record.chatdbRowID = fresh.chatdbRowID ?? record.chatdbRowID
      }
      // 仍未关联：按正文在 chat.db 中查找发出的消息
      if record.guid == nil, !record.text.isEmpty,
        let found = try? store.latestSentMessage(
          matchingText: record.text, chatID: nil, since: started.addingTimeInterval(-5))
      {
        record.guid = found.guid
        record.chatID = found.chatID
        record.service = found.service.isEmpty ? record.service : found.service
        link(&record, chatdbRowID: found.rowID)
      }
      guard let guid = record.guid,
        let status = try? store.messageSendStatus(guid: guid)
      else { continue }

      let newState: SendState
      switch status.state {
      case .pending: newState = .pending
      case .sent: newState = .sent
      case .delivered: newState = .delivered
      case .failed: newState = .failed
      }
      if newState != record.sendState || status.error != (record.errorCode ?? 0) {
        record.sendState = newState
        record.errorCode = status.error == 0 ? nil : status.error
        if status.wasDowngraded { record.service = "SMS" }
        update(record)
      }
      // 终态：送达或失败即停止；短信没有送达回执，已发出 30 秒后也停止
      if newState == .delivered || newState == .failed { return }
      if newState == .sent, record.service.uppercased() == "SMS",
        Date().timeIntervalSince(started) > 30
      {
        return
      }
    }
  }

  /// 把记录与 chat.db 行关联；若收信服务已为该行单独建了记录，则删除那条重复记录
  private func link(_ record: inout StoredMessage, chatdbRowID: Int64) {
    let snapshot = record
    _ = try? database.write { db in
      try StoredMessage
        .filter(Column("chatdbRowID") == chatdbRowID)
        .filter(Column("id") != snapshot.id)
        .deleteAll(db)
    }
    record.chatdbRowID = chatdbRowID
    update(record)
  }

  /// 保存并广播状态变化
  private func update(_ record: StoredMessage) {
    try? database.write { db in try record.update(db) }
    events.publish(.sendStatus(record))
  }

  /// 查询对方更可能走 iMessage 还是短信（基于本机历史记录推断）
  public func serviceAvailability(for handle: String) throws -> String {
    let store = try MessageStore(path: chatDBPath)
    switch try store.preferredService(forHandle: handle, region: region) {
    case .imessage: return "imessage"
    case .sms: return "sms"
    case .unknown: return "unknown"
    }
  }
}
