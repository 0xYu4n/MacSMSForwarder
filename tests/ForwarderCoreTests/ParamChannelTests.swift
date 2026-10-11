import CryptoKit
import Foundation
import Testing

@testable import ForwarderCore

/// 企业微信、钉钉、飞书、Telegram 等通用参数通道的请求构造与响应解析测试
struct ParamChannelTests {
  let payload = ForwardPayload(title: "+8613800138000", body: "验证码 123456", variables: [:])
  let now = Date(timeIntervalSince1970: 1_700_000_000)

  func json(_ request: URLRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
  }

  func form(_ request: URLRequest) -> String {
    String(decoding: request.httpBody ?? Data(), as: UTF8.self)
  }

  @Test func wecomAcceptsFullURL() throws {
    let channel = ParamChannel(
      type: .wecom,
      params: ["key": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc-123", "mentioned": "138,@all"])
    let request = try channel.makeRequest(payload)
    #expect(request.url?.absoluteString == "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc-123")
    let body = try json(request)
    let text = try #require(body["text"] as? [String: Any])
    #expect(text["content"] as? String == "+8613800138000\n验证码 123456")
    #expect(text["mentioned_mobile_list"] as? [String] == ["138", "@all"])
  }

  @Test func dingtalkSignature() throws {
    let channel = ParamChannel(type: .dingtalk, params: ["token": "TOKEN", "secret": "SECabc"])
    let request = try channel.makeRequest(payload, now: now)
    let url = try #require(request.url?.absoluteString)
    #expect(url.hasPrefix("https://oapi.dingtalk.com/robot/send?access_token=TOKEN&timestamp=1700000000000&sign="))
    // 独立计算期望签名
    let mac = HMAC<SHA256>.authenticationCode(
      for: Data("1700000000000\nSECabc".utf8), using: SymmetricKey(data: Data("SECabc".utf8)))
    let expected = TemplateRenderer.escape(Data(mac).base64EncodedString(), .url)
    #expect(url.hasSuffix("sign=\(expected)"))
  }

  @Test func feishuSignatureInBody() throws {
    let channel = ParamChannel(
      type: .feishu,
      params: ["token": "https://open.feishu.cn/open-apis/bot/v2/hook/xyz", "secret": "s"])
    let request = try channel.makeRequest(payload, now: now)
    #expect(request.url?.absoluteString == "https://open.feishu.cn/open-apis/bot/v2/hook/xyz")
    let body = try json(request)
    #expect(body["timestamp"] as? String == "1700000000")
    #expect((body["sign"] as? String)?.isEmpty == false)
    #expect(body["msg_type"] as? String == "text")
  }

  @Test func telegramCustomServer() throws {
    let channel = ParamChannel(
      type: .telegram, params: ["botToken": "1:AA", "chatID": "-100", "server": "https://tg.example.com/"])
    let request = try channel.makeRequest(payload)
    #expect(request.url?.absoluteString == "https://tg.example.com/bot1:AA/sendMessage")
    #expect(try json(request)["chat_id"] as? String == "-100")
  }

  @Test func pushdeerForm() throws {
    let request = try ParamChannel(type: .pushdeer, params: ["pushKey": "PDU1"]).makeRequest(payload)
    #expect(request.url?.absoluteString == "https://api2.pushdeer.com/message/push")
    #expect(form(request).contains("pushkey=PDU1"))
    #expect(form(request).contains("type=markdown"))
  }

  @Test func serverChanURLs() {
    #expect(ParamChannel.serverChanURL(sendKey: "SCT123abc") == "https://sctapi.ftqq.com/SCT123abc.send")
    #expect(
      ParamChannel.serverChanURL(sendKey: "sctp42tXYZ")
        == "https://42.push.ft07.com/send/sctp42tXYZ.send")
  }

  @Test func ntfyAndGotify() throws {
    let ntfy = try ParamChannel(
      type: .ntfy, params: ["topic": "sms", "priority": "9", "token": "tk"]
    ).makeRequest(payload)
    #expect(ntfy.url?.absoluteString == "https://ntfy.sh")
    #expect(try json(ntfy)["priority"] as? Int == 5)
    #expect(ntfy.value(forHTTPHeaderField: "Authorization") == "Bearer tk")

    let gotify = try ParamChannel(
      type: .gotify, params: ["server": "https://g.example.com/", "token": "AT"]
    ).makeRequest(payload)
    #expect(gotify.url?.absoluteString == "https://g.example.com/message")
    #expect(gotify.value(forHTTPHeaderField: "X-Gotify-Key") == "AT")
  }

  @Test func missingRequiredField() {
    #expect(throws: ForwardChannelError.self) {
      try ParamChannel(type: .telegram, params: ["botToken": "x"]).makeRequest(payload)
    }
  }

  @Test func responseEvaluation() {
    let wecom = ParamChannel(type: .wecom, params: [:])
    #expect(wecom.evaluate(status: 200, data: Data(#"{"errcode":0,"errmsg":"ok"}"#.utf8)).success)
    let failed = wecom.evaluate(status: 200, data: Data(#"{"errcode":93000,"errmsg":"invalid key"}"#.utf8))
    #expect(!failed.success)
    #expect(failed.detail == "invalid key")

    let pushplus = ParamChannel(type: .pushplus, params: [:])
    #expect(pushplus.evaluate(status: 200, data: Data(#"{"code":200,"msg":"请求成功"}"#.utf8)).success)
    #expect(!ParamChannel(type: .telegram, params: [:]).evaluate(status: 401, data: Data()).success)
  }
}
