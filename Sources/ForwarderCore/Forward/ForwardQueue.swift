import Foundation
import GRDB

/// 转发队列：从数据库取出到期任务并投递，失败后按指数退避重试
/// 任务持久化在 forward_jobs 表中，App 重启后会自动继续未完成的任务
public actor ForwardQueue {
  private let database: AppDatabase
  private let events: EventBus
  /// 最大尝试次数（含第一次）
  public var maxAttempts: Int = 6
  /// 首次重试等待秒数，之后每次翻倍：60、120、240…
  public var baseDelay: TimeInterval = 60
  /// 是否暂停投递（菜单栏「暂停转发」）
  public private(set) var isPaused = false

  /// 每个通道上一次投递的时间，用于限速
  private var lastSentAt: [Int64: Date] = [:]
  /// 后台循环任务
  private var loopTask: Task<Void, Never>?
  /// 用于提前唤醒循环（有新任务入队时）
  private var wakeContinuation: CheckedContinuation<Void, Never>?
  /// 自定义通道创建方式（测试时可注入假通道）
  private let channelMaker: @Sendable (ForwardChannelRecord) throws -> ForwardChannel

  public init(
    database: AppDatabase,
    events: EventBus,
    channelMaker: @escaping @Sendable (ForwardChannelRecord) throws -> ForwardChannel = {
      try ChannelFactory.make($0)
    }
  ) {
    self.database = database
    self.events = events
    self.channelMaker = channelMaker
  }

  // MARK: - 生命周期

  /// 启动后台循环；把上次异常退出时卡在 running 的任务恢复为 queued
  public func start() {
    guard loopTask == nil else { return }
    try? database.write { db in
      try db.execute(
        sql: "UPDATE forward_jobs SET status = ? WHERE status = ?",
        arguments: [ForwardJobStatus.queued.rawValue, ForwardJobStatus.running.rawValue])
    }
    loopTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.drain()
        await self.sleepUntilWoken(seconds: 2)
      }
    }
  }

  public func stop() {
    loopTask?.cancel()
    loopTask = nil
    wake()
  }

  public func setPaused(_ paused: Bool) {
    isPaused = paused
    if !paused { wake() }
  }

  /// 有新任务时调用，立即唤醒循环
  public func wake() {
    wakeContinuation?.resume()
    wakeContinuation = nil
  }

  /// 等待指定秒数或被提前唤醒
  private func sleepUntilWoken(seconds: TimeInterval) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      wakeContinuation = continuation
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await self?.wake()
      }
    }
  }

  // MARK: - 入队

  /// 为一条消息和命中的规则创建转发任务
  @discardableResult
  public func enqueue(message: StoredMessage, rules: [ForwardRule]) throws -> [ForwardJob] {
    let vars = RuleEngine.variables(for: message)
    var jobs: [ForwardJob] = []
    try database.write { db in
      for rule in rules {
        let title = TemplateRenderer.render(rule.titleTemplate, variables: vars)
        let body = TemplateRenderer.render(rule.bodyTemplate, variables: vars)
        for channelID in rule.channelIDs {
          var job = ForwardJob(
            messageID: message.id, ruleID: rule.id, channelID: channelID,
            title: title, body: body, variables: vars)
          try job.insert(db)
          jobs.append(job)
        }
      }
    }
    if !jobs.isEmpty { wake() }
    return jobs
  }

  /// 手动重试一个失败的任务
  public func retry(jobID: Int64) throws {
    try database.write { db in
      guard var job = try ForwardJob.fetchOne(db, key: jobID) else { return }
      job.status = .queued
      job.nextRetryAt = Date()
      job.updatedAt = Date()
      try job.update(db)
    }
    wake()
  }

  // MARK: - 投递

  /// 处理所有到期任务
  private func drain() async {
    guard !isPaused else { return }
    let now = Date()
    let due: [ForwardJob]
    do {
      due = try database.read { db in
        try ForwardJob
          .filter(Column("status") == ForwardJobStatus.queued.rawValue)
          .filter(Column("nextRetryAt") <= now)
          .order(Column("id"))
          .limit(50)
          .fetchAll(db)
      }
    } catch {
      return
    }
    for job in due {
      if Task.isCancelled || isPaused { return }
      await process(job)
    }
  }

  /// 投递单个任务并记录结果
  private func process(_ original: ForwardJob) async {
    var job = original
    guard let jobID = job.id else { return }

    // 读取通道配置；通道被删除或停用时直接结束任务
    let channel: ForwardChannelRecord?
    do {
      channel = try database.read { db in
        try ForwardChannelRecord.fetchOne(db, key: job.channelID)
      }
    } catch {
      return
    }
    guard let channel, channel.enabled else {
      job.status = .failed
      job.lastError = "通道不存在或已停用"
      job.updatedAt = Date()
      try? database.write { db in try job.update(db) }
      return
    }

    // 通道限速：距离上次投递不足最小间隔时，推迟任务
    if channel.minIntervalSeconds > 0, let last = lastSentAt[job.channelID] {
      let wait = channel.minIntervalSeconds - Date().timeIntervalSince(last)
      if wait > 0 {
        job.nextRetryAt = Date().addingTimeInterval(wait)
        try? database.write { db in try job.update(db) }
        return
      }
    }

    // 标记为执行中
    job.status = .running
    job.attempts += 1
    job.updatedAt = Date()
    try? database.write { db in try job.update(db) }

    let started = Date()
    let result: ForwardResult
    do {
      let sender = try channelMaker(channel)
      result = try await sender.send(
        ForwardPayload(title: job.title, body: job.body, variables: job.variables))
    } catch {
      result = ForwardResult(success: false, httpStatus: nil, detail: error.localizedDescription)
    }
    lastSentAt[job.channelID] = Date()
    let duration = Int(Date().timeIntervalSince(started) * 1000)

    // 更新任务状态：成功→done；失败且未超过次数→按退避时间重新排队；否则→failed
    if result.success {
      job.status = .done
      job.lastError = nil
    } else if job.attempts < maxAttempts {
      job.status = .queued
      job.lastError = result.detail
      let delay = baseDelay * pow(2, Double(job.attempts - 1))
      job.nextRetryAt = Date().addingTimeInterval(delay)
    } else {
      job.status = .failed
      job.lastError = result.detail
    }
    job.updatedAt = Date()

    var log = ForwardLog(
      jobID: jobID, channelID: channel.id, channelName: channel.name,
      success: result.success, httpStatus: result.httpStatus,
      detail: result.detail, durationMs: duration, title: job.title)
    let finalJob = job
    try? database.write { db in
      try finalJob.update(db)
      try log.insert(db)
    }
    events.publish(.forward(log))
  }

  /// 立即向某个通道发送测试推送（不入队、不重试）
  public func test(channel: ForwardChannelRecord) async -> ForwardResult {
    do {
      let sender = try channelMaker(channel)
      return try await sender.send(.sample())
    } catch {
      return ForwardResult(success: false, httpStatus: nil, detail: error.localizedDescription)
    }
  }
}
