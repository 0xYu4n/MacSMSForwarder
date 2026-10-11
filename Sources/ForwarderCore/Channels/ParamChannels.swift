import CryptoKit
import Foundation

// 基于通用参数（params）的各类推送通道实现
// 每个通道只负责「构造请求」与「判断响应是否成功」，发送流程由 ParamChannel 统一处理

/// 通用参数通道：根据通道类型构造请求并解析响应
public struct ParamChannel: ForwardChannel {
  public let type: ChannelType
  public let params: [String: String]
  let session: URLSession

  public init(type: ChannelType, params: [String: String], session: URLSession = .shared) {
    self.type = type
    self.params = params
    self.session = session
  }

  public func send(_ payload: ForwardPayload) async throws -> ForwardResult {
    let request = try makeRequest(payload)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ForwardChannelError.invalidResponse }
    return evaluate(status: http.statusCode, data: data)
  }

  // MARK: - 构造请求

  /// 构造请求（拆出以便单元测试）
  public func makeRequest(_ payload: ForwardPayload, now: Date = Date()) throws -> URLRequest {
    // IM 类机器人只有一段文本：标题 + 换行 + 正文
    let text = payload.title.isEmpty ? payload.body : "\(payload.title)\n\(payload.body)"

    switch type {
    case .wecom:
      let key = try extract(required("key"), after: "key=")
      var body: [String: Any] = ["msgtype": "text"]
      var content: [String: Any] = ["content": text]
      let mentioned = list(params["mentioned"])
      if !mentioned.isEmpty { content["mentioned_mobile_list"] = mentioned }
      body["text"] = content
      return try jsonRequest(
        "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=\(encode(key))", body)

    case .dingtalk:
      let token = try extract(required("token"), after: "access_token=")
      var url = "https://oapi.dingtalk.com/robot/send?access_token=\(encode(token))"
      // 加签：sign = Base64(HmacSHA256(secret, "毫秒时间戳\nsecret"))
      if let secret = value("secret") {
        let timestamp = String(Int64(now.timeIntervalSince1970 * 1000))
        let sign = hmacBase64(key: secret, message: "\(timestamp)\n\(secret)")
        url += "&timestamp=\(timestamp)&sign=\(encode(sign))"
      }
      var body: [String: Any] = ["msgtype": "text", "text": ["content": text]]
      let mobiles = list(params["atMobiles"])
      if !mobiles.isEmpty { body["at"] = ["atMobiles": mobiles] }
      return try jsonRequest(url, body)

    case .feishu:
      let token = try extract(required("token"), after: "/hook/")
      var body: [String: Any] = ["msg_type": "text", "content": ["text": text]]
      // 签名：sign = Base64(HmacSHA256(key: "秒级时间戳\nsecret", 消息为空))
      if let secret = value("secret") {
        let timestamp = String(Int(now.timeIntervalSince1970))
        body["timestamp"] = timestamp
        body["sign"] = hmacBase64(key: "\(timestamp)\n\(secret)", message: "")
      }
      return try jsonRequest("https://open.feishu.cn/open-apis/bot/v2/hook/\(encode(token))", body)

    case .telegram:
      let token = try required("botToken")
      let server = trimSlash(value("server") ?? "https://api.telegram.org")
      return try jsonRequest(
        "\(server)/bot\(token)/sendMessage",
        ["chat_id": try required("chatID"), "text": text, "disable_web_page_preview": true])

    case .pushdeer:
      let server = trimSlash(value("server") ?? "https://api2.pushdeer.com")
      return try formRequest(
        "\(server)/message/push",
        [
          ("pushkey", try required("pushKey")), ("text", payload.title.isEmpty ? payload.body : payload.title),
          ("desp", payload.title.isEmpty ? "" : payload.body), ("type", "markdown"),
        ])

    case .serverchan:
      let key = try required("sendKey")
      return try formRequest(
        Self.serverChanURL(sendKey: key),
        [("title", payload.title.isEmpty ? String(payload.body.prefix(32)) : payload.title), ("desp", payload.body)])

    case .pushplus:
      var body: [String: Any] = [
        "token": try required("token"), "title": payload.title, "content": payload.body, "template": "txt",
      ]
      if let topic = value("topic") { body["topic"] = topic }
      if let channel = value("channel") { body["channel"] = channel }
      return try jsonRequest("https://www.pushplus.plus/send", body)

    case .ntfy:
      // 使用 JSON 方式发布到服务器根地址，避免中文标题放在请求头中的编码问题
      let server = trimSlash(value("server") ?? "https://ntfy.sh")
      var body: [String: Any] = [
        "topic": try required("topic"), "title": payload.title, "message": payload.body,
      ]
      if let priority = Int(value("priority") ?? "") { body["priority"] = min(max(priority, 1), 5) }
      var request = try jsonRequest(server, body)
      if let token = value("token") { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
      return request

    case .gotify:
      let server = trimSlash(try required("server"))
      var body: [String: Any] = ["title": payload.title, "message": payload.body]
      if let priority = Int(value("priority") ?? "") { body["priority"] = priority }
      var request = try jsonRequest("\(server)/message", body)
      request.setValue(try required("token"), forHTTPHeaderField: "X-Gotify-Key")
      return request

    case .bark, .webhook:
      throw ForwardChannelError.misconfigured("该通道类型不使用通用参数")
    }
  }

  /// Server酱 Turbo 地址：sctp 开头的新版 Key 使用 {uid}.push.ft07.com
  public static func serverChanURL(sendKey: String) -> String {
    if sendKey.hasPrefix("sctp"),
      let match = sendKey.range(of: #"^sctp(\d+)t"#, options: .regularExpression)
    {
      let uid = sendKey[match].dropFirst(4).dropLast()
      return "https://\(uid).push.ft07.com/send/\(sendKey).send"
    }
    return "https://sctapi.ftqq.com/\(sendKey).send"
  }

  // MARK: - 解析响应

  /// 根据 HTTP 状态码和各平台的业务返回码判断是否成功
  func evaluate(status: Int, data: Data) -> ForwardResult {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let detail = snippet(data)
    guard (200..<300).contains(status) else {
      return ForwardResult(success: false, httpStatus: status, detail: detail)
    }
    let ok: Bool
    switch type {
    case .wecom, .dingtalk:
      // {"errcode":0,"errmsg":"ok"}
      ok = (json?["errcode"] as? Int) == 0
    case .feishu:
      // 新版 {"code":0}，旧版 {"StatusCode":0}
      ok = (json?["code"] as? Int) == 0 || (json?["StatusCode"] as? Int) == 0
    case .telegram:
      ok = (json?["ok"] as? Bool) == true
    case .pushdeer, .serverchan:
      ok = (json?["code"] as? Int) == 0
    case .pushplus:
      ok = (json?["code"] as? Int) == 200
    default:
      ok = true
    }
    // 失败时优先展示平台返回的错误描述
    let message =
      (json?["errmsg"] as? String) ?? (json?["msg"] as? String) ?? (json?["message"] as? String)
      ?? (json?["description"] as? String) ?? (json?["error"] as? String)
    return ForwardResult(success: ok, httpStatus: status, detail: ok ? (message ?? "ok") : (message ?? detail))
  }

  // MARK: - 工具方法

  /// 读取非空参数
  func value(_ key: String) -> String? {
    let v = params[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return v.isEmpty ? nil : v
  }

  /// 读取必填参数，缺失时抛出配置错误
  func required(_ key: String) throws -> String {
    guard let v = value(key) else {
      let label = ChannelCatalog.fields(for: type).first { $0.key == key }?.label ?? key
      throw ForwardChannelError.misconfigured("请填写「\(label)」")
    }
    return v
  }

  /// 用户粘贴了完整 Webhook 地址时，截取标记后面的部分（并去掉后续查询参数）
  func extract(_ raw: String, after marker: String) -> String {
    guard let range = raw.range(of: marker) else { return raw }
    let rest = raw[range.upperBound...]
    return String(rest.split(separator: "&").first ?? rest)
  }

  /// 逗号（中英文）分隔的列表
  func list(_ raw: String?) -> [String] {
    (raw ?? "").split(whereSeparator: { $0 == "," || $0 == "，" })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  func trimSlash(_ s: String) -> String {
    var s = s
    while s.hasSuffix("/") { s.removeLast() }
    return s
  }

  func encode(_ s: String) -> String {
    TemplateRenderer.escape(s, .url)
  }

  /// HMAC-SHA256 后 Base64 编码
  func hmacBase64(key: String, message: String) -> String {
    let mac = HMAC<SHA256>.authenticationCode(
      for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
    return Data(mac).base64EncodedString()
  }

  /// JSON POST 请求
  func jsonRequest(_ urlString: String, _ body: [String: Any]) throws -> URLRequest {
    guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
      throw ForwardChannelError.misconfigured("地址无效：\(urlString)")
    }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return request
  }

  /// 表单 POST 请求
  func formRequest(_ urlString: String, _ fields: [(String, String)]) throws -> URLRequest {
    guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
      throw ForwardChannelError.misconfigured("地址无效：\(urlString)")
    }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue(
      "application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(fields.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&").utf8)
    return request
  }
}
