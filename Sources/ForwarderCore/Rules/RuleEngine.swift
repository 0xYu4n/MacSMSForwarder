import Foundation

/// 规则引擎：判断一条消息命中哪些规则，并生成模板变量
public enum RuleEngine {
  /// 时间格式：2026-10-09 12:30:00
  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
  }()

  /// 本机名称（例如「张三的 MacBook Pro」）
  public static var deviceName: String {
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
  }

  /// 根据消息生成模板变量表
  public static func variables(for message: StoredMessage) -> [String: String] {
    [
      "from": message.handle,
      "text": message.text,
      "code": CodeExtractor.extract(from: message.text) ?? "",
      "service": message.service,
      "time": timeFormatter.string(from: message.date),
      "chat": message.chatID.map(String.init) ?? "",
      "device": deviceName,
    ]
  }

  /// 按优先级返回命中的规则（遇到 stopAfterMatch 的规则后停止）
  public static func matchingRules(for message: StoredMessage, rules: [ForwardRule])
    -> [ForwardRule]
  {
    var result: [ForwardRule] = []
    let ordered = rules.filter(\.enabled).sorted {
      ($0.priority, $0.id ?? 0) < ($1.priority, $1.id ?? 0)
    }
    for rule in ordered where matches(rule, message: message) {
      result.append(rule)
      if rule.stopAfterMatch { break }
    }
    return result
  }

  /// 判断单条规则是否命中；没有条件的规则匹配所有消息
  public static func matches(_ rule: ForwardRule, message: StoredMessage) -> Bool {
    guard !rule.conditions.isEmpty else { return true }
    switch rule.matchMode {
    case .all:
      return rule.conditions.allSatisfy { evaluate($0, message: message) }
    case .any:
      return rule.conditions.contains { evaluate($0, message: message) }
    }
  }

  /// 计算单个条件
  public static func evaluate(_ condition: RuleCondition, message: StoredMessage) -> Bool {
    // 布尔字段
    if condition.field.isBoolean {
      let actual: Bool
      switch condition.field {
      case .isGroup: actual = message.isGroup
      case .hasAttachment: actual = message.attachmentsCount > 0
      default: actual = false
      }
      switch condition.op {
      case .isTrue: return actual
      case .isFalse: return !actual
      default: return false
      }
    }

    // 文本字段
    let actual: String
    switch condition.field {
    case .sender: actual = message.handle
    case .text: actual = message.text
    case .service: actual = message.service
    default: actual = ""
    }
    let value = condition.value
    switch condition.op {
    case .contains:
      return actual.localizedCaseInsensitiveContains(value)
    case .notContains:
      return !actual.localizedCaseInsensitiveContains(value)
    case .equals:
      return actual.compare(value, options: [.caseInsensitive]) == .orderedSame
    case .hasPrefix:
      return actual.lowercased().hasPrefix(value.lowercased())
    case .regex:
      // 无效的正则视为不匹配，而不是崩溃
      guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive])
      else { return false }
      let range = NSRange(actual.startIndex..., in: actual)
      return regex.firstMatch(in: actual, range: range) != nil
    case .isTrue, .isFalse:
      return false
    }
  }
}
