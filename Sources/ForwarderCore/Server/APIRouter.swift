import Foundation
import GRDB

/// 本地 HTTP API 路由
///
/// 所有接口都需要请求头 `Authorization: Bearer <token>`：
/// - POST /api/v1/messages/send          发送消息
/// - GET  /api/v1/messages/{id}          查询单条消息及发送状态
/// - GET  /api/v1/messages               分页查询（direction / handle / since / limit / before_id）
/// - GET  /api/v1/handles/{handle}/service  推断对方走 iMessage 还是短信
/// - GET  /api/v1/events                 SSE 实时事件
/// - GET  /api/v1/health                 运行状况
public final class APIRouter: @unchecked Sendable {
  private let database: AppDatabase
  private let sendService: SendService
  private let events: EventBus
  /// 获取收信服务状态（由 App 层提供）
  private let ingestStatus: @Sendable () async -> IngestStatus

  public init(
    database: AppDatabase,
    sendService: SendService,
    events: EventBus,
    ingestStatus: @escaping @Sendable () async -> IngestStatus
  ) {
    self.database = database
    self.sendService = sendService
    self.events = events
    self.ingestStatus = ingestStatus
  }

  /// 处理一个请求
  public func handle(_ request: HTTPRequest) async -> HTTPRouteResult {
    // 首页：无需鉴权，返回简单说明，方便确认服务是否在线
    if request.path == "/" {
      return .response(.json(["name": "MacSMSForwarder", "docs": "/api/v1"]))
    }
    guard request.path.hasPrefix("/api/v1/") else {
      return .response(.error("接口不存在", status: 404))
    }
    guard let token = TokenManager.authenticate(request.headers["authorization"], in: database)
    else {
      return .response(.error("缺少或无效的 API Token", status: 401))
    }

    let parts = request.path.split(separator: "/").map(String.init)  // ["api","v1",...]
    let route = Array(parts.dropFirst(2))

    switch (request.method, route.count, route.first) {
    case ("POST", 2, "messages") where route[1] == "send":
      guard sendService.isEnabled else {
        return .response(.error("发送功能已关闭", status: 503))
      }
      guard token.canSend else { return .response(.error("该 Token 没有发送权限", status: 403)) }
      return .response(send(request))

    case ("GET", 1, "messages"):
      guard token.canRead else { return .response(.error("该 Token 没有读取权限", status: 403)) }
      return .response(list(request))

    case ("GET", 2, "messages"):
      guard token.canRead else { return .response(.error("该 Token 没有读取权限", status: 403)) }
      return .response(detail(id: route[1]))

    case ("GET", 3, "handles") where route[2] == "service":
      guard token.canRead else { return .response(.error("该 Token 没有读取权限", status: 403)) }
      let handle = route[1].removingPercentEncoding ?? route[1]
      do {
        let service = try sendService.serviceAvailability(for: handle)
        return .response(.json(["handle": handle, "service": service]))
      } catch {
        return .response(.error(error.localizedDescription, status: 500))
      }

    case ("GET", 1, "events"):
      guard token.canRead else { return .response(.error("该 Token 没有读取权限", status: 403)) }
      return .eventStream(events.subscribe())

    case ("GET", 1, "health"):
      return .response(await health())

    default:
      return .response(.error("接口不存在", status: 404))
    }
  }

  // MARK: - 各接口实现

  /// 发送消息
  private func send(_ request: HTTPRequest) -> HTTPResponse {
    let decoded: SendRequest
    do {
      decoded = try JSONDecoder().decode(SendRequest.self, from: request.body)
    } catch {
      return .error("请求体需为 JSON：{\"to\":\"+86...\",\"text\":\"...\"}", status: 400)
    }
    do {
      let record = try sendService.send(decoded, source: .api)
      // 202：已受理，实际发送在后台进行，可通过 GET /messages/{id} 查询状态
      return .json(APIMessage(record), status: 202)
    } catch {
      return .error(error.localizedDescription, status: 400)
    }
  }

  /// 查询单条消息
  private func detail(id: String) -> HTTPResponse {
    guard let id = Int64(id) else { return .error("ID 无效", status: 400) }
    let record = try? database.read { db in try StoredMessage.fetchOne(db, key: id) }
    guard let record else { return .error("消息不存在", status: 404) }
    return .json(APIMessage(record))
  }

  /// 分页查询消息
  private func list(_ request: HTTPRequest) -> HTTPResponse {
    let limit = min(max(Int(request.query["limit"] ?? "") ?? 50, 1), 500)
    let records: [StoredMessage]
    do {
      records = try database.read { db in
        var query = StoredMessage.all()
        if let direction = request.query["direction"], let d = MessageDirection(rawValue: direction) {
          query = query.filter(Column("direction") == d.rawValue)
        }
        if let handle = request.query["handle"], !handle.isEmpty {
          query = query.filter(Column("handle").like("%\(handle)%"))
        }
        if let since = request.query["since"], let date = ISO8601DateFormatter().date(from: since) {
          query = query.filter(Column("date") >= date)
        }
        if let before = request.query["before_id"], let id = Int64(before) {
          query = query.filter(Column("id") < id)
        }
        return try query.order(Column("id").desc).limit(limit).fetchAll(db)
      }
    } catch {
      return .error(error.localizedDescription, status: 500)
    }
    return .json(["messages": records.map(APIMessage.init)])
  }

  /// 运行状况
  private func health() async -> HTTPResponse {
    struct Health: Encodable {
      var ingest: String
      var full_disk_access: String
      var automation: String
      var messages_running: Bool
      var send_enabled: Bool
      var device: String
    }
    let status = await ingestStatus()
    let ingest: String
    switch status {
    case .running: ingest = "running"
    case .stopped: ingest = "stopped"
    case .permissionDenied: ingest = "permission_denied"
    case .error(let message): ingest = "error: \(message)"
    }
    return .json(
      Health(
        ingest: ingest,
        full_disk_access: Permissions.fullDiskAccess().rawValue,
        automation: Permissions.automation().rawValue,
        messages_running: Permissions.isMessagesRunning,
        send_enabled: sendService.isEnabled,
        device: RuleEngine.deviceName))
  }
}
