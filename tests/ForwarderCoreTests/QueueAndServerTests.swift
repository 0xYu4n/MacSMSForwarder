import Foundation
import GRDB
import Testing

@testable import ForwarderCore

/// 可控结果的假通道：按顺序返回预设结果
final class FakeChannel: ForwardChannel, @unchecked Sendable {
  private let queue = DispatchQueue(label: "fake-channel")
  private var results: [Bool]

  init(results: [Bool]) { self.results = results }

  func send(_ payload: ForwardPayload) async throws -> ForwardResult {
    let ok = queue.sync { results.isEmpty ? true : results.removeFirst() }
    return ForwardResult(success: ok, httpStatus: ok ? 200 : 500, detail: ok ? "ok" : "boom")
  }
}

struct QueueTests {
  /// 准备数据库：一个通道 + 一条消息
  func setup() throws -> (AppDatabase, ForwardChannelRecord, StoredMessage) {
    let db = try AppDatabase.inMemory()
    var channel = ForwardChannelRecord(type: .bark, name: "测试", bark: BarkConfig(deviceKeys: ["k"]))
    var message = StoredMessage(
      chatdbRowID: 1, direction: .incoming, service: "SMS", handle: "+86138", text: "验证码 1234")
    try db.write { d in
      try channel.insert(d)
      try message.insert(d)
    }
    return (db, channel, message)
  }

  /// 轮询等待条件成立（最多 5 秒）
  func waitUntil(_ condition: () throws -> Bool) async throws {
    for _ in 0..<100 {
      if try condition() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    Issue.record("等待超时")
  }

  @Test func successfulDeliveryWritesLog() async throws {
    let (db, channel, message) = try setup()
    let fake = FakeChannel(results: [true])
    let queue = ForwardQueue(database: db, events: EventBus(), channelMaker: { _ in fake })
    await queue.start()
    let rule = ForwardRule(id: nil, name: "r", channelIDs: [channel.id!], titleTemplate: "{{from}}", bodyTemplate: "{{code}}")
    let jobs = try await queue.enqueue(message: message, rules: [rule])
    #expect(jobs.count == 1)
    #expect(jobs[0].body == "1234")

    try await waitUntil {
      try db.read { d in try ForwardLog.fetchCount(d) } == 1
    }
    let job = try db.read { d in try ForwardJob.fetchOne(d) }
    #expect(job?.status == .done)
    await queue.stop()
  }

  @Test func failureSchedulesRetryWithBackoff() async throws {
    let (db, channel, message) = try setup()
    let fake = FakeChannel(results: [false])
    let queue = ForwardQueue(database: db, events: EventBus(), channelMaker: { _ in fake })
    await queue.start()
    try await queue.enqueue(message: message, rules: [ForwardRule(name: "r", channelIDs: [channel.id!])])

    try await waitUntil {
      try db.read { d in try ForwardLog.fetchCount(d) } == 1
    }
    let job = try #require(try db.read { d in try ForwardJob.fetchOne(d) })
    #expect(job.status == .queued)
    #expect(job.attempts == 1)
    // 第一次失败后约 60 秒后重试
    #expect(job.nextRetryAt.timeIntervalSinceNow > 50)
    await queue.stop()
  }
}

struct HTTPParseTests {
  @Test func parsesRequestWithBody() {
    let raw = "POST /api/v1/messages/send?x=1 HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer t\r\nContent-Length: 2\r\n\r\n{}"
    guard case .complete(let request) = HTTPServer.parse(Data(raw.utf8)) else {
      Issue.record("解析失败")
      return
    }
    #expect(request.method == "POST")
    #expect(request.path == "/api/v1/messages/send")
    #expect(request.query["x"] == "1")
    #expect(request.headers["authorization"] == "Bearer t")
    #expect(request.body == Data("{}".utf8))
  }

  @Test func waitsForFullBody() {
    let raw = "POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"
    guard case .incomplete = HTTPServer.parse(Data(raw.utf8)) else {
      Issue.record("应等待更多数据")
      return
    }
  }

  @Test func tokenRoundTrip() throws {
    let db = try AppDatabase.inMemory()
    let (plain, _) = try TokenManager.create(name: "t", canSend: true, canRead: false, in: db)
    #expect(plain.hasPrefix("msf_"))
    let token = TokenManager.authenticate("Bearer \(plain)", in: db)
    #expect(token?.canRead == false)
    #expect(token?.lastUsedAt != nil)
    #expect(TokenManager.authenticate("Bearer wrong", in: db) == nil)
    #expect(TokenManager.authenticate(nil, in: db) == nil)
  }
}
