import Foundation
import Testing

@testable import ForwarderCore

/// Bark 与 Webhook 请求构造测试（只断言请求内容，不发网络请求）
struct ChannelTests {
  let payload = ForwardPayload(
    title: "+8613800138000",
    body: "验证码 123456",
    variables: ["from": "+8613800138000", "text": "验证码 123456", "code": "123456"])

  /// 把请求体解析为字典
  func json(_ request: URLRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
  }

  @Test func barkSingleKey() throws {
    let channel = BarkChannel(config: BarkConfig(server: "https://api.day.app/", deviceKeys: ["KEY1"]))
    let request = try channel.makeRequest(payload)
    #expect(request.url?.absoluteString == "https://api.day.app/push")
    #expect(request.httpMethod == "POST")
    let body = try json(request)
    #expect(body["device_key"] as? String == "KEY1")
    #expect(body["title"] as? String == "+8613800138000")
    // 识别到验证码时自动复制
    #expect(body["copy"] as? String == "123456")
    #expect(body["autoCopy"] as? String == "1")
  }

  @Test func barkMultipleKeysAndNoCode() throws {
    var config = BarkConfig(deviceKeys: ["A", " ", "B"])
    config.autoCopyCode = false
    let request = try BarkChannel(config: config).makeRequest(payload)
    let body = try json(request)
    #expect(body["device_keys"] as? [String] == ["A", "B"])
    #expect(body["copy"] == nil)
  }

  @Test func barkRequiresKey() {
    #expect(throws: ForwardChannelError.self) {
      try BarkChannel(config: BarkConfig(deviceKeys: [])).makeRequest(payload)
    }
  }

  @Test func webhookJSONEscaping() throws {
    let config = WebhookConfig(
      url: "https://example.com/hook",
      headers: ["X-From": "{{from}}"],
      bodyTemplate: #"{"text":"{{text}}","t":"{{title}}"}"#)
    let tricky = ForwardPayload(title: "T", body: "B", variables: ["text": "a\"b", "from": "Tom"])
    let request = try WebhookChannel(config: config).makeRequest(tricky)
    let body = try json(request)
    #expect(body["text"] as? String == "a\"b")
    #expect(body["t"] as? String == "T")
    #expect(request.value(forHTTPHeaderField: "X-From") == "Tom")
    #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
  }

  @Test func webhookGETFormQuery() throws {
    let config = WebhookConfig(
      url: "https://example.com/hook?a=1", method: .GET, bodyFormat: .form,
      bodyTemplate: "text={{text}}")
    let request = try WebhookChannel(config: config).makeRequest(
      ForwardPayload(title: "", body: "", variables: ["text": "你好 world"]))
    #expect(request.httpBody == nil)
    #expect(request.url?.absoluteString == "https://example.com/hook?a=1&text=%E4%BD%A0%E5%A5%BD%20world")
  }

  @Test func webhookHMACSignature() throws {
    let config = WebhookConfig(url: "https://example.com", bodyTemplate: "{}", hmacSecret: "secret")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let request = try WebhookChannel(config: config).makeRequest(payload, now: now)
    #expect(request.value(forHTTPHeaderField: "X-Timestamp") == "1700000000")
    let signature = try #require(request.value(forHTTPHeaderField: "X-Signature"))
    #expect(signature.hasPrefix("sha256="))
    #expect(signature.count == 7 + 64)
  }

  @Test func webhookRejectsBadURL() {
    #expect(throws: ForwardChannelError.self) {
      try WebhookChannel(config: WebhookConfig(url: "ftp://x")).makeRequest(payload)
    }
  }
}
