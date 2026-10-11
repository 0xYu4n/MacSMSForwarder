import Foundation
import Testing

@testable import ForwarderCore

/// 规则匹配、模板渲染、验证码提取的单元测试
struct RuleEngineTests {
  /// 构造一条测试消息
  func message(
    _ text: String, from handle: String = "+8613800138000", service: String = "SMS",
    group: Bool = false
  ) -> StoredMessage {
    StoredMessage(
      id: 1, chatdbRowID: 100, direction: .incoming, service: service, handle: handle,
      chatID: 7, isGroup: group, text: text,
      date: Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test func emptyConditionsMatchEverything() {
    let rule = ForwardRule(name: "全部")
    #expect(RuleEngine.matches(rule, message: message("任意内容")))
  }

  @Test func containsIsCaseInsensitive() {
    let rule = ForwardRule(
      name: "验证码", conditions: [RuleCondition(field: .text, op: .contains, value: "CODE")])
    #expect(RuleEngine.matches(rule, message: message("your code is 1234")))
    #expect(!RuleEngine.matches(rule, message: message("hello")))
  }

  @Test func allVersusAny() {
    let conditions = [
      RuleCondition(field: .sender, op: .hasPrefix, value: "+86"),
      RuleCondition(field: .service, op: .equals, value: "imessage"),
    ]
    let all = ForwardRule(name: "all", matchMode: .all, conditions: conditions)
    let any = ForwardRule(name: "any", matchMode: .any, conditions: conditions)
    let sms = message("hi", service: "SMS")
    #expect(!RuleEngine.matches(all, message: sms))
    #expect(RuleEngine.matches(any, message: sms))
  }

  @Test func regexAndInvalidRegex() {
    let ok = ForwardRule(
      name: "r", conditions: [RuleCondition(field: .text, op: .regex, value: #"\d{6}"#)])
    let bad = ForwardRule(
      name: "r", conditions: [RuleCondition(field: .text, op: .regex, value: "([")])
    #expect(RuleEngine.matches(ok, message: message("验证码 123456")))
    // 无效正则不崩溃，按不匹配处理
    #expect(!RuleEngine.matches(bad, message: message("验证码 123456")))
  }

  @Test func booleanFields() {
    let rule = ForwardRule(
      name: "非群聊", conditions: [RuleCondition(field: .isGroup, op: .isFalse)])
    #expect(RuleEngine.matches(rule, message: message("a", group: false)))
    #expect(!RuleEngine.matches(rule, message: message("a", group: true)))
  }

  @Test func priorityAndStopAfterMatch() {
    let first = ForwardRule(id: 1, name: "A", priority: 10, stopAfterMatch: true)
    let second = ForwardRule(id: 2, name: "B", priority: 20)
    let disabled = ForwardRule(id: 3, name: "C", enabled: false, priority: 0)
    let matched = RuleEngine.matchingRules(for: message("x"), rules: [second, disabled, first])
    #expect(matched.map(\.name) == ["A"])
  }

  @Test func extractsCodeNearKeyword() {
    #expect(CodeExtractor.extract(from: "【某银行】您的验证码是 482913，5 分钟内有效。") == "482913")
    #expect(CodeExtractor.extract(from: "Your verification code: 7781") == "7781")
    // 没有关键词：不提取（避免把金额、尾号当验证码）
    #expect(CodeExtractor.extract(from: "您尾号 1234 的卡消费 5000 元") == nil)
    // 多个数字时取离关键词最近的
    #expect(CodeExtractor.extract(from: "订单 20231008 的验证码 5566") == "5566")
  }

  @Test func templateRendering() {
    let vars = ["from": "Tom", "text": "a\"b\nc"]
    #expect(TemplateRenderer.render("{{from}}: {{ text }}", variables: vars) == "Tom: a\"b\nc")
    #expect(TemplateRenderer.render("{{unknown}}x", variables: vars) == "x")
    #expect(
      TemplateRenderer.render(#"{"t":"{{text}}"}"#, variables: vars, escaping: .json)
        == #"{"t":"a\"b\nc"}"#)
    #expect(TemplateRenderer.render("q={{from}}", variables: ["from": "a b&c"], escaping: .url) == "q=a%20b%26c")
  }

  @Test func variablesIncludeCode() {
    let vars = RuleEngine.variables(for: message("验证码：9087"))
    #expect(vars["code"] == "9087")
    #expect(vars["from"] == "+8613800138000")
    #expect(vars["service"] == "SMS")
  }
}
