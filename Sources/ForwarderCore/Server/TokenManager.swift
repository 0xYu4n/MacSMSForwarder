import CryptoKit
import Foundation
import GRDB

/// API 令牌管理：生成、校验、删除
public enum TokenManager {
  /// 计算令牌的 SHA-256 十六进制哈希
  public static func hash(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// 生成新令牌：返回明文（只展示一次）和已入库的记录
  public static func create(
    name: String, canSend: Bool, canRead: Bool, in database: AppDatabase
  ) throws -> (plain: String, record: APIToken) {
    // 32 字节随机数 → base64url，前缀 msf_ 便于识别
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw NSError(domain: "TokenManager", code: Int(status))
    }
    let encoded = Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let plain = "msf_" + encoded
    var record = APIToken(
      name: name, tokenHash: hash(plain), prefix: String(plain.prefix(10)),
      canSend: canSend, canRead: canRead)
    try database.write { db in try record.insert(db) }
    return (plain, record)
  }

  /// 校验请求头中的 Bearer 令牌，成功时更新最后使用时间
  public static func authenticate(_ header: String?, in database: AppDatabase) -> APIToken? {
    guard let header, header.lowercased().hasPrefix("bearer ") else { return nil }
    let token = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    guard !token.isEmpty else { return nil }
    let digest = hash(token)
    return try? database.write { db -> APIToken? in
      guard var record = try APIToken.filter(Column("tokenHash") == digest).fetchOne(db) else {
        return nil
      }
      record.lastUsedAt = Date()
      try record.update(db)
      return record
    }
  }
}
