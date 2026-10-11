import Foundation

/// 验证码提取器：从短信正文中识别 4~8 位数字验证码
public enum CodeExtractor {
  /// 常见验证码关键词（中英文）
  private static let keywords = [
    "验证码", "校验码", "动态码", "确认码", "激活码", "安全码", "动态密码", "短信密码",
    "code", "otp", "verification", "passcode", "pin",
  ]

  /// 独立的 4~8 位数字（前后不能紧挨其他数字）
  private static let digitsPattern = try! NSRegularExpression(
    pattern: #"(?<![0-9])([0-9]{4,8})(?![0-9])"#)

  /// 提取验证码；没有关键词的消息不提取，避免把金额、尾号误认为验证码
  public static func extract(from text: String) -> String? {
    let lower = text.lowercased()
    // 找到所有关键词出现的位置
    let keywordRanges = keywords.compactMap { keyword -> Range<String.Index>? in
      lower.range(of: keyword)
    }
    guard !keywordRanges.isEmpty else { return nil }

    let ns = text as NSString
    let matches = digitsPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return nil }

    // 计算每个数字串到最近关键词的距离，取最近的那个
    let keywordOffsets = keywordRanges.map { lower.distance(from: lower.startIndex, to: $0.lowerBound) }
    var best: (code: String, distance: Int)?
    for match in matches {
      let range = match.range(at: 1)
      let candidate = ns.substring(with: range)
      // NSRange 以 UTF-16 计数，这里转换为字符偏移以便与关键词位置比较
      guard let swiftRange = Range(range, in: text) else { continue }
      let offset = text.distance(from: text.startIndex, to: swiftRange.lowerBound)
      let distance = keywordOffsets.map { abs($0 - offset) }.min() ?? Int.max
      if best == nil || distance < best!.distance {
        best = (candidate, distance)
      }
    }
    return best?.code
  }
}
