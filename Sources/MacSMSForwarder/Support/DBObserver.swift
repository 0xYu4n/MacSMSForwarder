import ForwarderCore
import Foundation
import GRDB
import SwiftUI

/// 通用的数据库观察器：查询结果变化时自动刷新界面
@MainActor
final class DBObserver<Value>: ObservableObject {
  @Published private(set) var value: Value
  private var cancellable: AnyDatabaseCancellable?

  /// - Parameters:
  ///   - initial: 首次查询完成前的默认值
  ///   - fetch: 查询闭包
  init(initial: Value, fetch: @escaping @Sendable (Database) throws -> Value) {
    value = initial
    let observation = ValueObservation.tracking(fetch)
    cancellable = observation.start(
      in: AppModel.shared.database.writer,
      scheduling: .immediate,
      onError: { _ in },
      onChange: { [weak self] newValue in
        self?.value = newValue
      })
  }
}
