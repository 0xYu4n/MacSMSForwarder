import Foundation
import Network

/// 解析后的 HTTP 请求
public struct HTTPRequest: Sendable {
  public var method: String
  /// 路径（不含查询参数）
  public var path: String
  /// 查询参数
  public var query: [String: String]
  /// 请求头（键统一为小写）
  public var headers: [String: String]
  public var body: Data
}

/// HTTP 响应
public struct HTTPResponse: Sendable {
  public var status: Int
  public var headers: [String: String]
  public var body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  /// 构造 JSON 响应
  public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
    let data = (try? JSONEncoder.api.encode(value)) ?? Data("{}".utf8)
    return HTTPResponse(
      status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
  }

  /// 构造错误响应：{"error": "..."}
  public static func error(_ message: String, status: Int) -> HTTPResponse {
    json(["error": message], status: status)
  }
}

/// 路由处理结果：普通响应，或 SSE 长连接
public enum HTTPRouteResult: Sendable {
  case response(HTTPResponse)
  /// SSE：返回一个事件流，服务器负责把每个事件写给客户端
  case eventStream(AsyncStream<AppEvent>)
}

/// 极简 HTTP/1.1 服务器（基于 Network.framework，无第三方依赖）
/// 只支持本 App 的 API 场景：短连接 JSON 请求 + SSE 推送
public final class HTTPServer: @unchecked Sendable {
  /// 请求体大小上限：1 MB
  static let maxBodySize = 1 << 20
  /// 请求头大小上限：32 KB
  static let maxHeaderSize = 32 << 10

  private let handler: @Sendable (HTTPRequest) async -> HTTPRouteResult
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "macsmsforwarder.http")

  public init(handler: @escaping @Sendable (HTTPRequest) async -> HTTPRouteResult) {
    self.handler = handler
  }

  /// 启动监听
  /// - Parameters:
  ///   - port: 端口
  ///   - localOnly: true 只监听 127.0.0.1，false 监听所有网卡（局域网可访问）
  public func start(port: UInt16, localOnly: Bool) throws {
    stop()
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw NSError(domain: "HTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "端口无效"])
    }
    if localOnly {
      params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
    }
    let listener = localOnly ? try NWListener(using: params) : try NWListener(using: params, on: nwPort)
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  public func stop() {
    listener?.cancel()
    listener = nil
  }

  // MARK: - 连接处理

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    receiveRequest(on: connection, buffer: Data())
  }

  /// 持续读取直到拿到完整请求（请求头 + Content-Length 指定的请求体）
  private func receiveRequest(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }

      if error != nil {
        connection.cancel()
        return
      }
      switch Self.parse(buffer) {
      case .incomplete:
        if isComplete || buffer.count > Self.maxHeaderSize + Self.maxBodySize {
          connection.cancel()
        } else {
          self.receiveRequest(on: connection, buffer: buffer)
        }
      case .invalid(let status, let message):
        self.write(.error(message, status: status), to: connection, close: true)
      case .complete(let request):
        Task {
          let result = await self.handler(request)
          switch result {
          case .response(let response):
            self.write(response, to: connection, close: true)
          case .eventStream(let stream):
            self.streamEvents(stream, to: connection)
          }
        }
      }
    }
  }

  // MARK: - 请求解析

  enum ParseResult {
    case incomplete
    case invalid(Int, String)
    case complete(HTTPRequest)
  }

  /// 解析 HTTP 请求报文
  static func parse(_ buffer: Data) -> ParseResult {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerEnd = buffer.range(of: separator) else {
      return buffer.count > maxHeaderSize ? .invalid(431, "请求头过大") : .incomplete
    }
    let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
    var lines = headerText.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return .invalid(400, "请求格式错误") }
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return .invalid(400, "请求行格式错误") }

    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[key] = value
    }

    let length = Int(headers["content-length"] ?? "0") ?? 0
    guard length <= maxBodySize else { return .invalid(413, "请求体过大") }
    let bodyStart = headerEnd.upperBound
    guard buffer.count - bodyStart >= length else { return .incomplete }
    let body = buffer.subdata(in: bodyStart..<(bodyStart + length))

    // 拆分路径和查询参数
    let target = String(requestLine[1])
    let components = URLComponents(string: target)
    var query: [String: String] = [:]
    for item in components?.queryItems ?? [] {
      query[item.name] = item.value ?? ""
    }
    let path = components?.path ?? target
    return .complete(
      HTTPRequest(
        method: String(requestLine[0]).uppercased(),
        path: path.isEmpty ? "/" : path,
        query: query,
        headers: headers,
        body: body))
  }

  // MARK: - 响应输出

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 201: return "Created"
    case 202: return "Accepted"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 413: return "Payload Too Large"
    case 431: return "Request Header Fields Too Large"
    case 500: return "Internal Server Error"
    case 503: return "Service Unavailable"
    default: return "Status"
    }
  }

  /// 写出完整响应
  private func write(_ response: HTTPResponse, to connection: NWConnection, close: Bool) {
    var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
    var headers = response.headers
    headers["Content-Length"] = String(response.body.count)
    headers["Connection"] = close ? "close" : "keep-alive"
    for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
      head += "\(key): \(value)\r\n"
    }
    head += "\r\n"
    let data = Data(head.utf8) + response.body
    connection.send(
      content: data,
      completion: .contentProcessed { _ in
        if close { connection.cancel() }
      })
  }

  /// SSE：先写响应头，然后把事件逐条写出；客户端断开后停止
  private func streamEvents(_ stream: AsyncStream<AppEvent>, to connection: NWConnection) {
    let head =
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n: connected\n\n"
    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

    let task = Task {
      // 每 25 秒发一次心跳注释，防止中间代理断开空闲连接
      let heartbeat = Task {
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 25_000_000_000)
          connection.send(content: Data(": ping\n\n".utf8), completion: .contentProcessed { _ in })
        }
      }
      defer { heartbeat.cancel() }
      for await event in stream {
        if Task.isCancelled { break }
        var chunk = "event: \(event.name)\n"
        chunk += "data: " + String(decoding: event.jsonData(), as: UTF8.self) + "\n\n"
        connection.send(content: Data(chunk.utf8), completion: .contentProcessed { _ in })
      }
    }
    // 连接失效时结束推送任务（取消后 AsyncStream 的订阅也会随之释放）
    connection.stateUpdateHandler = { state in
      switch state {
      case .failed, .cancelled:
        task.cancel()
      default:
        break
      }
    }
    // 监听客户端关闭：读到 EOF 即取消连接
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
      if isComplete || error != nil {
        task.cancel()
        connection.cancel()
      }
    }
  }
}
