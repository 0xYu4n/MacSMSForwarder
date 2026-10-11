import Foundation
import GRDB

// MARK: - 消息记录

/// 消息方向：收到 / 发出
public enum MessageDirection: String, Codable, Sendable, CaseIterable {
  case incoming
  case outgoing
}

/// 发送状态（仅对发出的消息有意义）
public enum SendState: String, Codable, Sendable {
  /// 收到的消息，无发送状态
  case none
  /// 已提交给「信息」App，等待 chat.db 中出现对应记录
  case pending
  /// 已发出
  case sent
  /// 对方已送达（iMessage 才有可靠的送达回执）
  case delivered
  /// 发送失败
  case failed
}

/// 消息来源：由 chat.db 监听得到，还是通过 API / 界面主动发送
public enum MessageSource: String, Codable, Sendable {
  case watcher
  case api
  case ui
}

/// 自有数据库中的一条消息（收到的、或自己发出的）
public struct StoredMessage: Codable, Identifiable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "messages"

  /// 自增主键
  public var id: Int64?
  /// chat.db 中 message 表的 ROWID，用于去重；API 发送的消息在匹配成功前为 nil
  public var chatdbRowID: Int64?
  /// chat.db 中的消息 GUID
  public var guid: String?
  public var direction: MessageDirection
  /// 服务类型：iMessage / SMS / RCS 等（原样保存 chat.db 中的字符串）
  public var service: String
  /// 对方号码或邮箱
  public var handle: String
  /// chat.db 中的会话 ID
  public var chatID: Int64?
  /// 是否群聊
  public var isGroup: Bool
  /// 正文
  public var text: String
  /// 附件数量
  public var attachmentsCount: Int
  /// 消息时间
  public var date: Date
  public var sendState: SendState
  /// 发送失败时 chat.db 中的错误码
  public var errorCode: Int?
  /// 错误描述（AppleScript 失败等）
  public var errorMessage: String?
  public var source: MessageSource

  public init(
    id: Int64? = nil,
    chatdbRowID: Int64? = nil,
    guid: String? = nil,
    direction: MessageDirection,
    service: String,
    handle: String,
    chatID: Int64? = nil,
    isGroup: Bool = false,
    text: String,
    attachmentsCount: Int = 0,
    date: Date = Date(),
    sendState: SendState = .none,
    errorCode: Int? = nil,
    errorMessage: String? = nil,
    source: MessageSource = .watcher
  ) {
    self.id = id
    self.chatdbRowID = chatdbRowID
    self.guid = guid
    self.direction = direction
    self.service = service
    self.handle = handle
    self.chatID = chatID
    self.isGroup = isGroup
    self.text = text
    self.attachmentsCount = attachmentsCount
    self.date = date
    self.sendState = sendState
    self.errorCode = errorCode
    self.errorMessage = errorMessage
    self.source = source
  }

  /// 插入后回填自增 ID
  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

// MARK: - 转发规则

/// 规则条件可匹配的字段
public enum RuleField: String, Codable, Sendable, CaseIterable, Identifiable {
  case sender
  case text
  case service
  case isGroup
  case hasAttachment

  public var id: String { rawValue }

  /// 界面显示名
  public var title: String {
    switch self {
    case .sender: return "发件人"
    case .text: return "内容"
    case .service: return "服务类型"
    case .isGroup: return "是群聊"
    case .hasAttachment: return "含附件"
    }
  }

  /// 是否为布尔字段（布尔字段只能用「是 / 否」运算符）
  public var isBoolean: Bool {
    self == .isGroup || self == .hasAttachment
  }
}

/// 条件运算符
public enum RuleOperator: String, Codable, Sendable, CaseIterable, Identifiable {
  case contains
  case notContains
  case equals
  case hasPrefix
  case regex
  case isTrue
  case isFalse

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .contains: return "包含"
    case .notContains: return "不包含"
    case .equals: return "等于"
    case .hasPrefix: return "开头是"
    case .regex: return "正则匹配"
    case .isTrue: return "是"
    case .isFalse: return "否"
    }
  }

  /// 文本字段可用的运算符
  public static let textOperators: [RuleOperator] = [
    .contains, .notContains, .equals, .hasPrefix, .regex,
  ]
  /// 布尔字段可用的运算符
  public static let boolOperators: [RuleOperator] = [.isTrue, .isFalse]
}

/// 单个规则条件
public struct RuleCondition: Codable, Equatable, Hashable, Sendable, Identifiable {
  public var id: UUID
  public var field: RuleField
  public var op: RuleOperator
  public var value: String

  public init(id: UUID = UUID(), field: RuleField, op: RuleOperator, value: String = "") {
    self.id = id
    self.field = field
    self.op = op
    self.value = value
  }
}

/// 多个条件的组合方式
public enum MatchMode: String, Codable, Sendable, CaseIterable {
  /// 全部满足
  case all
  /// 任一满足
  case any
}

/// 转发规则：满足条件的收到消息，按模板渲染后投递到指定通道
public struct ForwardRule: Codable, Identifiable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "rules"

  public var id: Int64?
  public var name: String
  public var enabled: Bool
  /// 优先级：数字越小越先匹配
  public var priority: Int
  public var matchMode: MatchMode
  /// 条件列表（以 JSON 存储）；为空表示匹配所有消息
  public var conditions: [RuleCondition]
  /// 目标通道 ID 列表（以 JSON 存储）
  public var channelIDs: [Int64]
  /// 标题模板，例如「{{from}}」
  public var titleTemplate: String
  /// 正文模板，例如「{{text}}」
  public var bodyTemplate: String
  /// 匹配成功后是否停止匹配后续规则
  public var stopAfterMatch: Bool
  public var createdAt: Date

  public init(
    id: Int64? = nil,
    name: String,
    enabled: Bool = true,
    priority: Int = 100,
    matchMode: MatchMode = .all,
    conditions: [RuleCondition] = [],
    channelIDs: [Int64] = [],
    titleTemplate: String = ForwardRule.defaultTitleTemplate,
    bodyTemplate: String = ForwardRule.defaultBodyTemplate,
    stopAfterMatch: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.priority = priority
    self.matchMode = matchMode
    self.conditions = conditions
    self.channelIDs = channelIDs
    self.titleTemplate = titleTemplate
    self.bodyTemplate = bodyTemplate
    self.stopAfterMatch = stopAfterMatch
    self.createdAt = createdAt
  }

  public static let defaultTitleTemplate = "{{from}}"
  public static let defaultBodyTemplate = "{{text}}"

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

// MARK: - 转发通道

/// 通道类型（新增通道：在此加一个 case，并在 ChannelCatalog / ChannelFactory 中注册）
public enum ChannelType: String, Codable, Sendable, CaseIterable, Identifiable {
  case bark
  case webhook
  case wecom
  case dingtalk
  case feishu
  case telegram
  case pushdeer
  case serverchan
  case pushplus
  case ntfy
  case gotify

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .bark: return "Bark"
    case .webhook: return "Webhook"
    case .wecom: return "企业微信机器人"
    case .dingtalk: return "钉钉机器人"
    case .feishu: return "飞书机器人"
    case .telegram: return "Telegram Bot"
    case .pushdeer: return "PushDeer"
    case .serverchan: return "Server酱"
    case .pushplus: return "PushPlus"
    case .ntfy: return "ntfy"
    case .gotify: return "Gotify"
    }
  }

  /// 界面图标（SF Symbols）
  public var symbol: String {
    switch self {
    case .bark: return "bell.badge"
    case .webhook: return "link"
    case .wecom: return "person.2.wave.2"
    case .dingtalk: return "bell.and.waves.left.and.right"
    case .feishu: return "paperplane.circle"
    case .telegram: return "paperplane"
    case .pushdeer: return "hare"
    case .serverchan: return "server.rack"
    case .pushplus: return "plus.bubble"
    case .ntfy: return "bell.circle"
    case .gotify: return "antenna.radiowaves.left.and.right"
    }
  }

  /// 分组：用于「添加通道」菜单的分区
  public var group: String {
    switch self {
    case .bark, .pushdeer, .serverchan, .pushplus: return "手机推送"
    case .wecom, .dingtalk, .feishu, .telegram: return "IM 机器人"
    case .ntfy, .gotify: return "自建推送"
    case .webhook: return "通用"
    }
  }
}

/// Bark 推送级别
public enum BarkLevel: String, Codable, Sendable, CaseIterable {
  case active
  case timeSensitive
  case passive
  case critical

  public var title: String {
    switch self {
    case .active: return "默认"
    case .timeSensitive: return "时效性"
    case .passive: return "静默"
    case .critical: return "重要警告"
    }
  }
}

/// Bark 通道配置
public struct BarkConfig: Codable, Equatable, Sendable {
  /// 服务器地址，默认官方服务器，也可填自建 bark-server
  public var server: String
  /// 设备 Key，支持多个（多台设备同时推送）
  public var deviceKeys: [String]
  /// 推送分组
  public var group: String
  /// 推送图标 URL
  public var icon: String
  /// 铃声名称
  public var sound: String
  public var level: BarkLevel
  /// 点击推送时打开的 URL
  public var url: String
  /// 是否保存到 Bark 历史
  public var isArchive: Bool
  /// 识别到验证码时，自动复制验证码到 iPhone 剪贴板
  public var autoCopyCode: Bool

  public init(
    server: String = "https://api.day.app",
    deviceKeys: [String] = [],
    group: String = "Mac短信转发",
    icon: String = "",
    sound: String = "",
    level: BarkLevel = .active,
    url: String = "",
    isArchive: Bool = true,
    autoCopyCode: Bool = true
  ) {
    self.server = server
    self.deviceKeys = deviceKeys
    self.group = group
    self.icon = icon
    self.sound = sound
    self.level = level
    self.url = url
    self.isArchive = isArchive
    self.autoCopyCode = autoCopyCode
  }
}

/// Webhook 请求方法
public enum HTTPMethod: String, Codable, Sendable, CaseIterable {
  case GET
  case POST
  case PUT
}

/// Webhook 请求体格式
public enum WebhookBodyFormat: String, Codable, Sendable, CaseIterable {
  case json
  case form
  case text

  public var contentType: String {
    switch self {
    case .json: return "application/json; charset=utf-8"
    case .form: return "application/x-www-form-urlencoded; charset=utf-8"
    case .text: return "text/plain; charset=utf-8"
    }
  }
}

/// 通用 Webhook 通道配置
public struct WebhookConfig: Codable, Equatable, Sendable {
  /// 请求地址（支持模板变量，变量值会自动做 URL 编码）
  public var url: String
  public var method: HTTPMethod
  /// 自定义请求头
  public var headers: [String: String]
  public var bodyFormat: WebhookBodyFormat
  /// 请求体模板（JSON 格式时变量值会自动做 JSON 转义）
  public var bodyTemplate: String
  /// 超时秒数
  public var timeout: Double
  /// 是否忽略 HTTPS 证书错误（自签名证书的内网服务）
  public var ignoreSSLErrors: Bool
  /// HMAC-SHA256 签名密钥；非空时在请求头 X-Signature 中附带签名
  public var hmacSecret: String

  public init(
    url: String = "",
    method: HTTPMethod = .POST,
    headers: [String: String] = [:],
    bodyFormat: WebhookBodyFormat = .json,
    bodyTemplate: String = WebhookConfig.defaultBodyTemplate,
    timeout: Double = 10,
    ignoreSSLErrors: Bool = false,
    hmacSecret: String = ""
  ) {
    self.url = url
    self.method = method
    self.headers = headers
    self.bodyFormat = bodyFormat
    self.bodyTemplate = bodyTemplate
    self.timeout = timeout
    self.ignoreSSLErrors = ignoreSSLErrors
    self.hmacSecret = hmacSecret
  }

  /// 默认 JSON 请求体模板，覆盖所有常用变量，方便接入 n8n / Home Assistant
  public static let defaultBodyTemplate = """
    {
      "from": "{{from}}",
      "text": "{{text}}",
      "code": "{{code}}",
      "service": "{{service}}",
      "time": "{{time}}",
      "chat": "{{chat}}",
      "device": "{{device}}"
    }
    """
}

/// 转发通道
public struct ForwardChannelRecord: Codable, Identifiable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "channels"

  public var id: Int64?
  public var type: ChannelType
  public var name: String
  public var enabled: Bool
  /// 同一通道两次推送的最小间隔（秒），0 表示不限速
  public var minIntervalSeconds: Double
  /// Bark 配置（type == .bark 时有效，以 JSON 存储）
  public var bark: BarkConfig?
  /// Webhook 配置（type == .webhook 时有效，以 JSON 存储）
  public var webhook: WebhookConfig?
  /// 其他通道的通用参数（键名见 ChannelCatalog，以 JSON 存储）
  public var params: [String: String]
  public var createdAt: Date

  public init(
    id: Int64? = nil,
    type: ChannelType,
    name: String,
    enabled: Bool = true,
    minIntervalSeconds: Double = 0,
    bark: BarkConfig? = nil,
    webhook: WebhookConfig? = nil,
    params: [String: String] = [:],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.type = type
    self.name = name
    self.enabled = enabled
    self.minIntervalSeconds = minIntervalSeconds
    self.bark = bark
    self.webhook = webhook
    self.params = params
    self.createdAt = createdAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

// MARK: - 转发任务与日志

/// 转发任务状态
public enum ForwardJobStatus: String, Codable, Sendable {
  case queued
  case running
  case done
  case failed
}

/// 一次待投递（或已投递）的转发任务，持久化以保证重启后可继续重试
public struct ForwardJob: Codable, Identifiable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "forward_jobs"

  public var id: Int64?
  public var messageID: Int64?
  public var ruleID: Int64?
  public var channelID: Int64
  /// 已渲染好的标题
  public var title: String
  /// 已渲染好的正文
  public var body: String
  /// 模板变量快照（Webhook 等通道会用它渲染自己的模板）
  public var variables: [String: String]
  public var status: ForwardJobStatus
  /// 已尝试次数
  public var attempts: Int
  /// 下一次可执行的时间（用于指数退避）
  public var nextRetryAt: Date
  public var lastError: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: Int64? = nil,
    messageID: Int64?,
    ruleID: Int64?,
    channelID: Int64,
    title: String,
    body: String,
    variables: [String: String],
    status: ForwardJobStatus = .queued,
    attempts: Int = 0,
    nextRetryAt: Date = Date(),
    lastError: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.messageID = messageID
    self.ruleID = ruleID
    self.channelID = channelID
    self.title = title
    self.body = body
    self.variables = variables
    self.status = status
    self.attempts = attempts
    self.nextRetryAt = nextRetryAt
    self.lastError = lastError
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

/// 每一次投递尝试的日志
public struct ForwardLog: Codable, Identifiable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "forward_logs"

  public var id: Int64?
  public var jobID: Int64?
  public var channelID: Int64?
  /// 记录时的通道名（通道删除后仍可读）
  public var channelName: String
  public var success: Bool
  public var httpStatus: Int?
  /// 响应摘要或错误信息
  public var detail: String
  public var durationMs: Int
  /// 冗余保存标题，便于日志列表直接展示
  public var title: String
  public var createdAt: Date

  public init(
    id: Int64? = nil,
    jobID: Int64?,
    channelID: Int64?,
    channelName: String,
    success: Bool,
    httpStatus: Int?,
    detail: String,
    durationMs: Int,
    title: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.jobID = jobID
    self.channelID = channelID
    self.channelName = channelName
    self.success = success
    self.httpStatus = httpStatus
    self.detail = detail
    self.durationMs = durationMs
    self.title = title
    self.createdAt = createdAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

// MARK: - API Token

/// API 访问令牌（只保存 SHA-256 哈希，明文仅在创建时展示一次）
public struct APIToken: Codable, Identifiable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "api_tokens"

  public var id: Int64?
  public var name: String
  /// 令牌哈希（十六进制 SHA-256）
  public var tokenHash: String
  /// 令牌前几位，便于在界面上辨认
  public var prefix: String
  /// 是否允许发送消息
  public var canSend: Bool
  /// 是否允许读取消息
  public var canRead: Bool
  public var createdAt: Date
  public var lastUsedAt: Date?

  public init(
    id: Int64? = nil,
    name: String,
    tokenHash: String,
    prefix: String,
    canSend: Bool = true,
    canRead: Bool = true,
    createdAt: Date = Date(),
    lastUsedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.tokenHash = tokenHash
    self.prefix = prefix
    self.canSend = canSend
    self.canRead = canRead
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

// MARK: - 同步进度

/// 键值对形式的内部状态（例如已处理到的 chat.db ROWID）
public struct SyncState: Codable, FetchableRecord, PersistableRecord, Sendable {
  public static let databaseTableName = "sync_state"

  public var key: String
  public var value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}
