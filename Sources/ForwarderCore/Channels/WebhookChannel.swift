import CryptoKit
import Foundation

/// 通用 Webhook 通道：可对接 n8n、Home Assistant、自建服务等任意 HTTP 接口
public struct WebhookChannel: ForwardChannel {
  public let config: WebhookConfig

  public init(config: WebhookConfig) {
    self.config = config
  }

  /// 构造请求（单独拆出，便于单元测试断言请求内容）
  public func makeRequest(_ payload: ForwardPayload, now: Date = Date()) throws -> URLRequest {
    let vars = payload.variables.merging(
      ["title": payload.title, "body": payload.body], uniquingKeysWith: { current, _ in current })

    // URL 中的变量按 URL 编码替换
    let urlString = TemplateRenderer.render(
      config.url.trimmingCharacters(in: .whitespacesAndNewlines), variables: vars, escaping: .url)
    guard var components = URLComponents(string: urlString),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else {
      throw ForwardChannelError.misconfigured("URL 无效，需以 http:// 或 https:// 开头")
    }

    // 按请求体格式选择变量转义方式
    let escaping: TemplateEscaping
    switch config.bodyFormat {
    case .json: escaping = .json
    case .form: escaping = .url
    case .text: escaping = .none
    }
    let body = TemplateRenderer.render(config.bodyTemplate, variables: vars, escaping: escaping)

    var request: URLRequest
    if config.method == .GET {
      // GET 请求：表单格式的模板内容追加到查询参数，其他格式忽略请求体
      if config.bodyFormat == .form, !body.isEmpty {
        let existing = components.percentEncodedQuery.map { $0 + "&" } ?? ""
        components.percentEncodedQuery = existing + body
      }
      guard let url = components.url else { throw ForwardChannelError.misconfigured("URL 无效") }
      request = URLRequest(url: url, timeoutInterval: max(1, config.timeout))
    } else {
      guard let url = components.url else { throw ForwardChannelError.misconfigured("URL 无效") }
      request = URLRequest(url: url, timeoutInterval: max(1, config.timeout))
      request.httpBody = Data(body.utf8)
      request.setValue(config.bodyFormat.contentType, forHTTPHeaderField: "Content-Type")
    }
    request.httpMethod = config.method.rawValue
    request.setValue("MacSMSForwarder", forHTTPHeaderField: "User-Agent")

    // 自定义请求头（值也支持模板变量）
    for (key, value) in config.headers where !key.isEmpty {
      request.setValue(
        TemplateRenderer.render(value, variables: vars), forHTTPHeaderField: key)
    }

    // HMAC 签名：签名内容为「时间戳 + 换行 + 请求体」，接收端可据此校验来源与防重放
    if !config.hmacSecret.isEmpty {
      let timestamp = String(Int(now.timeIntervalSince1970))
      let message = Data((timestamp + "\n").utf8) + (request.httpBody ?? Data())
      let mac = HMAC<SHA256>.authenticationCode(
        for: message, using: SymmetricKey(data: Data(config.hmacSecret.utf8)))
      let signature = mac.map { String(format: "%02x", $0) }.joined()
      request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
      request.setValue("sha256=" + signature, forHTTPHeaderField: "X-Signature")
    }
    return request
  }

  public func send(_ payload: ForwardPayload) async throws -> ForwardResult {
    let request = try makeRequest(payload)
    // 忽略证书错误时使用专门的会话代理
    let session: URLSession
    if config.ignoreSSLErrors {
      session = URLSession(
        configuration: .ephemeral, delegate: InsecureTrustDelegate(), delegateQueue: nil)
    } else {
      session = .shared
    }
    defer { if config.ignoreSSLErrors { session.finishTasksAndInvalidate() } }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ForwardChannelError.invalidResponse }
    return ForwardResult(
      success: (200..<300).contains(http.statusCode),
      httpStatus: http.statusCode,
      detail: snippet(data)
    )
  }
}

/// 信任任意服务器证书的会话代理（仅在用户显式开启「忽略证书错误」时使用）
final class InsecureTrustDelegate: NSObject, URLSessionDelegate {
  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    {
      completionHandler(.useCredential, URLCredential(trust: trust))
    } else {
      completionHandler(.performDefaultHandling, nil)
    }
  }
}
