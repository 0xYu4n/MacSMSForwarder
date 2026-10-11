import Foundation

/// 模板变量的转义方式
public enum TemplateEscaping: Sendable {
  /// 原样替换
  case none
  /// JSON 字符串转义（不含两侧引号），用于 JSON 请求体
  case json
  /// URL 查询参数编码，用于 URL 和表单请求体
  case url
}

/// 极简模板渲染器：把 {{变量名}} 替换为变量值，未知变量替换为空字符串
public enum TemplateRenderer {
  /// 匹配 {{ name }}，变量名允许字母、数字和下划线，两侧允许空格
  private static let pattern = try! NSRegularExpression(
    pattern: #"\{\{\s*([A-Za-z0-9_]+)\s*\}\}"#)

  /// 渲染模板
  /// - Parameters:
  ///   - template: 模板字符串
  ///   - variables: 变量表
  ///   - escaping: 变量值的转义方式
  public static func render(
    _ template: String,
    variables: [String: String],
    escaping: TemplateEscaping = .none
  ) -> String {
    let ns = template as NSString
    let matches = pattern.matches(in: template, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return template }

    var result = ""
    var cursor = 0
    for match in matches {
      // 拼接上一个变量与本变量之间的原文
      result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      let name = ns.substring(with: match.range(at: 1))
      let raw = variables[name] ?? ""
      result += escape(raw, escaping)
      cursor = match.range.location + match.range.length
    }
    result += ns.substring(from: cursor)
    return result
  }

  /// 按指定方式转义变量值
  static func escape(_ value: String, _ escaping: TemplateEscaping) -> String {
    switch escaping {
    case .none:
      return value
    case .json:
      return jsonEscape(value)
    case .url:
      // 只保留 RFC 3986 中的非保留字符，其余全部百分号编码
      var allowed = CharacterSet.alphanumerics
      allowed.insert(charactersIn: "-._~")
      return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
  }

  /// JSON 字符串转义：处理引号、反斜杠和控制字符
  static func jsonEscape(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.count)
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      default:
        if scalar.value < 0x20 {
          // 其余控制字符统一用 \uXXXX 表示
          out += String(format: "\\u%04X", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out
  }

  /// 界面中展示的可用变量说明
  public static let availableVariables: [(name: String, description: String)] = [
    ("from", "发件人号码或邮箱"),
    ("text", "消息正文"),
    ("code", "自动提取的验证码（没有则为空）"),
    ("service", "服务类型：iMessage / SMS"),
    ("time", "收到时间，例如 2026-10-09 12:30:00"),
    ("chat", "会话标识（群聊时为群 ID）"),
    ("device", "本机名称"),
  ]
}
