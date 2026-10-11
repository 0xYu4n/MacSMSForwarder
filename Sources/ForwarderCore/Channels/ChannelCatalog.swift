import Foundation

/// 通道配置表单中的一个字段
public struct ChannelField: Sendable, Identifiable {
  /// 存入 params 的键名
  public let key: String
  /// 显示名
  public let label: String
  /// 输入框占位提示
  public let placeholder: String
  /// 是否必填
  public let required: Bool
  /// 是否以密码框显示（Token、密钥等）
  public let secure: Bool
  /// 默认值
  public let defaultValue: String

  public var id: String { key }

  public init(
    _ key: String, _ label: String, placeholder: String = "", required: Bool = false,
    secure: Bool = false, defaultValue: String = ""
  ) {
    self.key = key
    self.label = label
    self.placeholder = placeholder
    self.required = required
    self.secure = secure
    self.defaultValue = defaultValue
  }
}

/// 各通道的配置字段与说明（Bark 和 Webhook 有专用表单，不在此列）
public enum ChannelCatalog {
  /// 通道需要填写的字段
  public static func fields(for type: ChannelType) -> [ChannelField] {
    switch type {
    case .bark, .webhook:
      return []
    case .wecom:
      return [
        ChannelField("key", "机器人 Key", placeholder: "Webhook 地址中 key= 后面的部分，或直接粘贴完整地址", required: true, secure: true),
        ChannelField("mentioned", "@成员手机号", placeholder: "可选，多个用逗号分隔；填 @all 提醒所有人"),
      ]
    case .dingtalk:
      return [
        ChannelField("token", "Access Token", placeholder: "Webhook 地址中 access_token= 后面的部分，或完整地址", required: true, secure: true),
        ChannelField("secret", "加签密钥", placeholder: "可选，安全设置选择「加签」时填写（SEC 开头）", secure: true),
        ChannelField("atMobiles", "@成员手机号", placeholder: "可选，多个用逗号分隔"),
      ]
    case .feishu:
      return [
        ChannelField("token", "Webhook Token", placeholder: "地址 /hook/ 后面的部分，或完整地址", required: true, secure: true),
        ChannelField("secret", "签名校验密钥", placeholder: "可选，安全设置开启「签名校验」时填写", secure: true),
      ]
    case .telegram:
      return [
        ChannelField("botToken", "Bot Token", placeholder: "从 @BotFather 获取，形如 123456:ABC…", required: true, secure: true),
        ChannelField("chatID", "Chat ID", placeholder: "用户、群组或频道 ID（群组为负数）", required: true),
        ChannelField("server", "API 地址", placeholder: "https://api.telegram.org（国内可填反代地址）", defaultValue: "https://api.telegram.org"),
      ]
    case .pushdeer:
      return [
        ChannelField("pushKey", "PushKey", placeholder: "PDU 开头的 Key", required: true, secure: true),
        ChannelField("server", "服务器", placeholder: "https://api2.pushdeer.com（自建可修改）", defaultValue: "https://api2.pushdeer.com"),
      ]
    case .serverchan:
      return [
        ChannelField("sendKey", "SendKey", placeholder: "SCT 或 sctp 开头的 SendKey", required: true, secure: true)
      ]
    case .pushplus:
      return [
        ChannelField("token", "Token", placeholder: "PushPlus 用户 Token", required: true, secure: true),
        ChannelField("topic", "群组编码", placeholder: "可选，一对多推送时填写"),
        ChannelField("channel", "发送渠道", placeholder: "可选：wechat / webhook / mail 等，默认 wechat"),
      ]
    case .ntfy:
      return [
        ChannelField("server", "服务器", placeholder: "https://ntfy.sh", defaultValue: "https://ntfy.sh"),
        ChannelField("topic", "主题", placeholder: "订阅的 topic 名称", required: true),
        ChannelField("token", "访问令牌", placeholder: "可选，受保护的主题需要", secure: true),
        ChannelField("priority", "优先级", placeholder: "1~5，默认 3", defaultValue: "3"),
      ]
    case .gotify:
      return [
        ChannelField("server", "服务器", placeholder: "https://gotify.example.com", required: true),
        ChannelField("token", "应用 Token", placeholder: "Gotify 中创建应用得到的 Token", required: true, secure: true),
        ChannelField("priority", "优先级", placeholder: "0~10，默认 5", defaultValue: "5"),
      ]
    }
  }

  /// 简短的接入说明
  public static func help(for type: ChannelType) -> String {
    switch type {
    case .bark: return "iPhone 安装 Bark，复制首页推送地址中的 Key。"
    case .webhook: return "向任意 HTTP 接口推送，可对接 n8n、Home Assistant 等。"
    case .wecom: return "企业微信群 › 群设置 › 群机器人 › 添加机器人，复制 Webhook 地址。"
    case .dingtalk: return "钉钉群 › 设置 › 机器人 › 添加自定义机器人。安全设置选「加签」最省事；若选「自定义关键词」，请在规则模板中包含该关键词。"
    case .feishu: return "飞书群 › 设置 › 群机器人 › 添加自定义机器人，复制 Webhook 地址。"
    case .telegram: return "向 @BotFather 创建机器人获得 Token；给机器人发一条消息后，访问 api.telegram.org/bot<Token>/getUpdates 可查到 Chat ID。"
    case .pushdeer: return "安装 PushDeer App 或使用其轻 App，登录后在「Key」页面创建 PushKey。"
    case .serverchan: return "登录 sct.ftqq.com 获取 SendKey，消息可推送到微信等渠道。"
    case .pushplus: return "登录 pushplus.plus 获取 Token，默认推送到微信公众号。"
    case .ntfy: return "在 ntfy App 中订阅同名主题即可收到推送，也支持自建服务器。"
    case .gotify: return "自建 Gotify 服务，在 Apps 中创建应用获取 Token。"
    }
  }

  /// 新建通道时的默认参数
  public static func defaultParams(for type: ChannelType) -> [String: String] {
    var params: [String: String] = [:]
    for field in fields(for: type) where !field.defaultValue.isEmpty {
      params[field.key] = field.defaultValue
    }
    return params
  }

  /// 创建一个带默认配置的新通道
  public static func newChannel(_ type: ChannelType) -> ForwardChannelRecord {
    switch type {
    case .bark:
      return ForwardChannelRecord(type: .bark, name: type.title, bark: BarkConfig())
    case .webhook:
      return ForwardChannelRecord(type: .webhook, name: type.title, webhook: WebhookConfig())
    default:
      return ForwardChannelRecord(type: type, name: type.title, params: defaultParams(for: type))
    }
  }

  /// 列表中显示的通道摘要（不暴露密钥）
  public static func summary(_ channel: ForwardChannelRecord) -> String {
    switch channel.type {
    case .bark:
      let count = channel.bark?.deviceKeys.filter { !$0.isEmpty }.count ?? 0
      return "\(channel.bark?.server ?? "") · \(count) 台设备"
    case .webhook:
      return "\(channel.webhook?.method.rawValue ?? "") \(channel.webhook?.url ?? "")"
    case .telegram:
      return "Chat ID：\(channel.params["chatID"] ?? "")"
    case .ntfy:
      return "\(channel.params["server"] ?? "https://ntfy.sh")/\(channel.params["topic"] ?? "")"
    case .gotify:
      return channel.params["server"] ?? ""
    default:
      return help(for: channel.type).components(separatedBy: "，").first ?? ""
    }
  }
}
