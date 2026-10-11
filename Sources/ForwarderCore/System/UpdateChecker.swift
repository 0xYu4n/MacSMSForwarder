import Foundation

/// GitHub 上的一个发布版本
public struct ReleaseInfo: Sendable, Equatable {
  /// 版本号（已去掉前缀 v），例如 0.2.0
  public let version: String
  /// 发布页地址（用户确认更新后在浏览器中打开）
  public let pageURL: URL
  /// 更新说明
  public let notes: String
  public let publishedAt: Date?
}

/// 检查更新的结果
public enum UpdateCheckResult: Sendable, Equatable {
  /// 有新版本
  case available(ReleaseInfo)
  /// 已是最新
  case upToDate(latest: String)
  /// 检查失败（网络错误、还没有发布版本等）
  case failed(String)
}

/// 版本更新检测：读取 GitHub 最新正式版并与当前版本比较
public enum UpdateChecker {
  /// 仓库（owner/name）
  public static let repository = "0xYu4n/MacSMSForwarder"
  /// 发布列表页面（检查失败时也可让用户手动前往）
  public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

  /// 查询最新正式版
  /// - Parameters:
  ///   - currentVersion: 当前 App 的版本号
  ///   - session: 网络会话（测试时可注入）
  public static func check(currentVersion: String, session: URLSession = .shared) async
    -> UpdateCheckResult
  {
    let api = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    var request = URLRequest(url: api, timeoutInterval: 15)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("MacSMSForwarder/\(currentVersion)", forHTTPHeaderField: "User-Agent")

    do {
      let (data, response) = try await session.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if status == 404 { return .failed("暂无已发布的版本") }
      guard (200..<300).contains(status) else {
        // 未登录的 GitHub API 每小时限 60 次，触发限流时返回 403
        return .failed(status == 403 ? "GitHub 请求过于频繁，请稍后再试" : "GitHub 返回 HTTP \(status)")
      }
      guard let release = parse(data) else { return .failed("无法解析 GitHub 返回的数据") }
      return isNewer(release.version, than: currentVersion)
        ? .available(release) : .upToDate(latest: release.version)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// 解析 GitHub releases/latest 接口返回的 JSON
  static func parse(_ data: Data) -> ReleaseInfo? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = json["tag_name"] as? String,
      let page = (json["html_url"] as? String).flatMap(URL.init(string:))
    else { return nil }
    let published = (json["published_at"] as? String).flatMap {
      ISO8601DateFormatter().date(from: $0)
    }
    return ReleaseInfo(
      version: normalize(tag), pageURL: page, notes: json["body"] as? String ?? "",
      publishedAt: published)
  }

  /// 去掉前缀 v / V 和首尾空白
  static func normalize(_ version: String) -> String {
    var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
    if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
    return v
  }

  /// 判断 latest 是否比 current 新
  /// 只比较「主.次.修订」数字部分；current 带 -dev 等后缀时视为同号的预发布版，低于同号正式版
  public static func isNewer(_ latest: String, than current: String) -> Bool {
    let (latestNumbers, latestPre) = split(normalize(latest))
    let (currentNumbers, currentPre) = split(normalize(current))
    let count = max(latestNumbers.count, currentNumbers.count, 3)
    for i in 0..<count {
      let a = i < latestNumbers.count ? latestNumbers[i] : 0
      let b = i < currentNumbers.count ? currentNumbers[i] : 0
      if a != b { return a > b }
    }
    // 数字相同：当前是预发布版、最新是正式版 → 有更新
    return currentPre && !latestPre
  }

  /// 拆分版本号：数字部分 + 是否带预发布后缀
  private static func split(_ version: String) -> ([Int], Bool) {
    let parts = version.split(separator: "-", maxSplits: 1)
    let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
    return (numbers, parts.count > 1)
  }
}
