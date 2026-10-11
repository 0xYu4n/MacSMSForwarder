import Foundation
import GRDB

/// 自有数据库：封装 GRDB 连接池、表结构迁移和常用读写操作
public final class AppDatabase: @unchecked Sendable {
  /// GRDB 写入器（App 中为 DatabasePool，测试中为内存 DatabaseQueue）
  public let writer: any DatabaseWriter

  /// 用指定写入器初始化并执行迁移
  public init(writer: any DatabaseWriter) throws {
    self.writer = writer
    try Self.migrator.migrate(writer)
  }

  /// 默认数据库文件位置：~/Library/Application Support/MacSMSForwarder/data.sqlite
  public static func defaultURL() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = support.appendingPathComponent("MacSMSForwarder", isDirectory: true)
    // 目录权限 0700：数据库里有短信内容和通道密钥，只允许当前用户访问
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return dir.appendingPathComponent("data.sqlite")
  }

  /// 打开磁盘上的数据库（App 正式使用）
  public static func openDefault() throws -> AppDatabase {
    let url = try defaultURL()
    var config = Configuration()
    config.label = "MacSMSForwarder"
    let pool = try DatabasePool(path: url.path, configuration: config)
    return try AppDatabase(writer: pool)
  }

  /// 创建内存数据库（单元测试使用）
  public static func inMemory() throws -> AppDatabase {
    try AppDatabase(writer: DatabaseQueue())
  }

  // MARK: - 迁移

  /// 表结构迁移：新版本只追加新的 migration，不修改已发布的 migration
  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    migrator.registerMigration("v1") { db in
      // 消息表
      try db.create(table: "messages") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("chatdbRowID", .integer).unique()
        t.column("guid", .text).indexed()
        t.column("direction", .text).notNull()
        t.column("service", .text).notNull()
        t.column("handle", .text).notNull().indexed()
        t.column("chatID", .integer)
        t.column("isGroup", .boolean).notNull().defaults(to: false)
        t.column("text", .text).notNull()
        t.column("attachmentsCount", .integer).notNull().defaults(to: 0)
        t.column("date", .datetime).notNull().indexed()
        t.column("sendState", .text).notNull()
        t.column("errorCode", .integer)
        t.column("errorMessage", .text)
        t.column("source", .text).notNull()
      }

      // 转发规则表
      try db.create(table: "rules") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("name", .text).notNull()
        t.column("enabled", .boolean).notNull().defaults(to: true)
        t.column("priority", .integer).notNull().defaults(to: 100)
        t.column("matchMode", .text).notNull()
        t.column("conditions", .text).notNull()
        t.column("channelIDs", .text).notNull()
        t.column("titleTemplate", .text).notNull()
        t.column("bodyTemplate", .text).notNull()
        t.column("stopAfterMatch", .boolean).notNull().defaults(to: false)
        t.column("createdAt", .datetime).notNull()
      }

      // 转发通道表
      try db.create(table: "channels") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("type", .text).notNull()
        t.column("name", .text).notNull()
        t.column("enabled", .boolean).notNull().defaults(to: true)
        t.column("minIntervalSeconds", .double).notNull().defaults(to: 0)
        t.column("bark", .text)
        t.column("webhook", .text)
        t.column("createdAt", .datetime).notNull()
      }

      // 转发任务表
      try db.create(table: "forward_jobs") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("messageID", .integer).references("messages", onDelete: .setNull)
        t.column("ruleID", .integer).references("rules", onDelete: .setNull)
        t.column("channelID", .integer).notNull().references("channels", onDelete: .cascade)
        t.column("title", .text).notNull()
        t.column("body", .text).notNull()
        t.column("variables", .text).notNull()
        t.column("status", .text).notNull().indexed()
        t.column("attempts", .integer).notNull().defaults(to: 0)
        t.column("nextRetryAt", .datetime).notNull().indexed()
        t.column("lastError", .text)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }

      // 转发日志表
      try db.create(table: "forward_logs") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("jobID", .integer).references("forward_jobs", onDelete: .setNull)
        t.column("channelID", .integer).references("channels", onDelete: .setNull)
        t.column("channelName", .text).notNull()
        t.column("success", .boolean).notNull()
        t.column("httpStatus", .integer)
        t.column("detail", .text).notNull()
        t.column("durationMs", .integer).notNull()
        t.column("title", .text).notNull()
        t.column("createdAt", .datetime).notNull().indexed()
      }

      // API 令牌表
      try db.create(table: "api_tokens") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("name", .text).notNull()
        t.column("tokenHash", .text).notNull().unique()
        t.column("prefix", .text).notNull()
        t.column("canSend", .boolean).notNull().defaults(to: true)
        t.column("canRead", .boolean).notNull().defaults(to: true)
        t.column("createdAt", .datetime).notNull()
        t.column("lastUsedAt", .datetime)
      }

      // 内部同步状态表
      try db.create(table: "sync_state") { t in
        t.primaryKey("key", .text)
        t.column("value", .text).notNull()
      }
    }

    // v2：新增多种转发通道，通用参数存放在 params 列
    migrator.registerMigration("v2-channel-params") { db in
      try db.alter(table: "channels") { t in
        t.add(column: "params", .text).notNull().defaults(to: "{}")
      }
    }

    return migrator
  }
}

// MARK: - 同步读写封装

extension AppDatabase {
  /// 同步写入（在 async 函数中调用 writer.write 会被编译器解析为异步重载，这里显式使用同步版本）
  @discardableResult
  public func write<T>(_ updates: (Database) throws -> T) throws -> T {
    try writer.write(updates)
  }

  /// 同步读取
  public func read<T>(_ value: (Database) throws -> T) throws -> T {
    try writer.read(value)
  }
}

// MARK: - 同步状态读写

extension AppDatabase {
  /// 已处理到的 chat.db ROWID 对应的键名
  public static let lastRowIDKey = "last_chatdb_rowid"

  /// 读取同步状态
  public func syncValue(_ key: String) throws -> String? {
    try writer.read { db in try SyncState.fetchOne(db, key: key)?.value }
  }

  /// 删除同步状态
  public func removeSyncValue(_ key: String) throws {
    try writer.write { db in _ = try SyncState.deleteOne(db, key: key) }
  }

  /// 写入同步状态
  public func setSyncValue(_ key: String, _ value: String) throws {
    try writer.write { db in try SyncState(key: key, value: value).save(db) }
  }
}

// MARK: - 数据清理

extension AppDatabase {
  /// 删除指定天数之前的消息和日志（0 表示不清理）
  public func purge(olderThanDays days: Int) throws {
    guard days > 0 else { return }
    let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
    try writer.write { db in
      _ = try ForwardLog.filter(Column("createdAt") < cutoff).deleteAll(db)
      _ = try ForwardJob
        .filter(Column("createdAt") < cutoff)
        .filter([ForwardJobStatus.done.rawValue, ForwardJobStatus.failed.rawValue]
          .contains(Column("status")))
        .deleteAll(db)
      _ = try StoredMessage.filter(Column("date") < cutoff).deleteAll(db)
    }
  }
}
