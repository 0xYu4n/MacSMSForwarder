import Foundation

/// 系统内部事件，用于 SSE 推送和界面状态刷新
public enum AppEvent: Sendable {
  /// 新消息入库（收到或发出）
  case message(StoredMessage)
  /// 发出消息的状态变化
  case sendStatus(StoredMessage)
  /// 一次转发尝试完成
  case forward(ForwardLog)

  /// SSE 事件名
  public var name: String {
    switch self {
    case .message: return "message"
    case .sendStatus: return "send_status"
    case .forward: return "forward"
    }
  }

  /// 事件内容的 JSON
  public func jsonData() -> Data {
    let encoder = JSONEncoder.api
    switch self {
    case .message(let m), .sendStatus(let m):
      return (try? encoder.encode(APIMessage(m))) ?? Data("{}".utf8)
    case .forward(let log):
      return (try? encoder.encode(log)) ?? Data("{}".utf8)
    }
  }
}

/// 简单的一对多事件广播：每个订阅者拿到一个独立的 AsyncStream
public final class EventBus: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<AppEvent>.Continuation] = [:]

  public init() {}

  /// 订阅事件；流结束时自动取消订阅
  public func subscribe() -> AsyncStream<AppEvent> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(200)) { continuation in
      lock.lock()
      continuations[id] = continuation
      lock.unlock()
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.lock()
        self.continuations[id] = nil
        self.lock.unlock()
      }
    }
  }

  /// 广播事件给所有订阅者
  public func publish(_ event: AppEvent) {
    lock.lock()
    let targets = Array(continuations.values)
    lock.unlock()
    for continuation in targets {
      continuation.yield(event)
    }
  }
}

extension JSONEncoder {
  /// API 输出统一使用的编码器：ISO8601 时间、键排序
  static var api: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

/// API 对外暴露的消息结构（字段名使用下划线风格，与内部模型解耦）
public struct APIMessage: Codable, Sendable {
  public var id: Int64?
  public var guid: String?
  public var direction: String
  public var service: String
  public var handle: String
  public var chat_id: Int64?
  public var is_group: Bool
  public var text: String
  public var attachments: Int
  public var date: Date
  public var send_state: String
  public var error_code: Int?
  public var error_message: String?
  public var source: String
  /// 自动提取的验证码，方便自动化直接使用
  public var code: String?

  public init(_ m: StoredMessage) {
    id = m.id
    guid = m.guid
    direction = m.direction.rawValue
    service = m.service
    handle = m.handle
    chat_id = m.chatID
    is_group = m.isGroup
    text = m.text
    attachments = m.attachmentsCount
    date = m.date
    send_state = m.sendState.rawValue
    error_code = m.errorCode
    error_message = m.errorMessage
    source = m.source.rawValue
    code = m.direction == .incoming ? CodeExtractor.extract(from: m.text) : nil
  }
}
