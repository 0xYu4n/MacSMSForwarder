import Foundation

/// Bark 推送通道
/// 接口文档：https://bark.day.app —— POST {server}/push，JSON 请求体
public struct BarkChannel: ForwardChannel {
  public let config: BarkConfig
  let session: URLSession

  public init(config: BarkConfig, session: URLSession = .shared) {
    self.config = config
    self.session = session
  }

  /// 构造请求（单独拆出，便于单元测试断言请求内容）
  public func makeRequest(_ payload: ForwardPayload) throws -> URLRequest {
    let keys = config.deviceKeys
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !keys.isEmpty else { throw ForwardChannelError.misconfigured("至少填写一个设备 Key") }

    var server = config.server.trimmingCharacters(in: .whitespacesAndNewlines)
    if server.isEmpty { server = "https://api.day.app" }
    while server.hasSuffix("/") { server.removeLast() }
    guard let url = URL(string: server + "/push") else {
      throw ForwardChannelError.misconfigured("服务器地址无效")
    }

    // 组装请求体：只放非空字段，保持请求简洁
    var body: [String: Any] = [
      "title": payload.title,
      "body": payload.body,
      "isArchive": config.isArchive ? "1" : "0",
      "level": config.level.rawValue,
    ]
    // 单个设备用 device_key，多个设备用 device_keys
    if keys.count == 1 {
      body["device_key"] = keys[0]
    } else {
      body["device_keys"] = keys
    }
    if !config.group.isEmpty { body["group"] = config.group }
    if !config.icon.isEmpty { body["icon"] = config.icon }
    if !config.sound.isEmpty { body["sound"] = config.sound }
    if !config.url.isEmpty {
      body["url"] = TemplateRenderer.render(config.url, variables: payload.variables, escaping: .url)
    }
    // 识别到验证码时：复制内容设为验证码，并开启自动复制
    if config.autoCopyCode, let code = payload.variables["code"], !code.isEmpty {
      body["copy"] = code
      body["autoCopy"] = "1"
    }

    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return request
  }

  public func send(_ payload: ForwardPayload) async throws -> ForwardResult {
    let request = try makeRequest(payload)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ForwardChannelError.invalidResponse }

    // Bark 成功时返回 {"code":200,"message":"success",...}
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let code = json?["code"] as? Int
    let message = json?["message"] as? String
    let ok = (200..<300).contains(http.statusCode) && (code == nil || code == 200)
    return ForwardResult(
      success: ok,
      httpStatus: http.statusCode,
      detail: message ?? snippet(data)
    )
  }
}
