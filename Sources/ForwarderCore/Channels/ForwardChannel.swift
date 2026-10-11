import Foundation

/// 投递给通道的内容
public struct ForwardPayload: Sendable, Equatable {
  /// 规则模板渲染后的标题
  public var title: String
  /// 规则模板渲染后的正文
  public var body: String
  /// 原始模板变量（通道可用它渲染自己的模板，例如 Webhook 请求体）
  public var variables: [String: String]

  public init(title: String, body: String, variables: [String: String]) {
    self.title = title
    self.body = body
    self.variables = variables
  }

  /// 测试推送用的示例内容
  public static func sample() -> ForwardPayload {
    let vars: [String: String] = [
      "from": "+8613800138000",
      "text": "【Mac短信转发】这是一条测试消息，验证码 123456。",
      "code": "123456",
      "service": "SMS",
      "time": ISO8601DateFormatter().string(from: Date()),
      "chat": "0",
      "device": RuleEngine.deviceName,
    ]
    return ForwardPayload(title: "测试推送 · Mac短信转发", body: vars["text"]!, variables: vars)
  }
}

/// 一次投递的结果
public struct ForwardResult: Sendable, Equatable {
  public var success: Bool
  public var httpStatus: Int?
  /// 响应摘要或错误说明
  public var detail: String

  public init(success: Bool, httpStatus: Int?, detail: String) {
    self.success = success
    self.httpStatus = httpStatus
    self.detail = detail
  }
}

/// 通道错误
public enum ForwardChannelError: LocalizedError {
  case misconfigured(String)
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .misconfigured(let reason): return "通道配置错误：\(reason)"
    case .invalidResponse: return "服务器返回了无法识别的响应"
    }
  }
}

/// 转发通道协议：新增通道只需实现此协议并在 ChannelFactory 中注册
public protocol ForwardChannel: Sendable {
  /// 投递一条内容；网络错误抛出异常，服务器业务错误返回 success == false
  func send(_ payload: ForwardPayload) async throws -> ForwardResult
}

/// 根据通道记录创建通道实例
public enum ChannelFactory {
  public static func make(_ record: ForwardChannelRecord) throws -> ForwardChannel {
    switch record.type {
    case .bark:
      guard let config = record.bark else { throw ForwardChannelError.misconfigured("缺少 Bark 配置") }
      return BarkChannel(config: config)
    case .webhook:
      guard let config = record.webhook else {
        throw ForwardChannelError.misconfigured("缺少 Webhook 配置")
      }
      return WebhookChannel(config: config)
    default:
      // 其余通道均基于通用参数实现
      return ParamChannel(type: record.type, params: record.params)
    }
  }
}

/// 截取响应文本，避免日志过长
func snippet(_ data: Data, limit: Int = 300) -> String {
  let text = String(decoding: data.prefix(limit * 4), as: UTF8.self)
  return text.count > limit ? String(text.prefix(limit)) + "…" : text
}
