import ForwarderCore
import GRDB
import SwiftUI

/// 转发日志页：每次投递尝试的结果，失败任务可手动重试
struct LogsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var onlyFailures = false

  @StateObject private var logs = DBObserver<[ForwardLog]>(initial: []) { db in
    try ForwardLog.order(Column("id").desc).limit(500).fetchAll(db)
  }
  /// 仍在排队等待重试的任务数
  @StateObject private var pendingCount = DBObserver<Int>(initial: 0) { db in
    try ForwardJob.filter(
      [ForwardJobStatus.queued.rawValue, ForwardJobStatus.running.rawValue].contains(Column("status"))
    ).fetchCount(db)
  }

  private var shown: [ForwardLog] {
    onlyFailures ? logs.value.filter { !$0.success } : logs.value
  }

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(
        title: "转发日志",
        subtitle: pendingCount.value > 0 ? "\(pendingCount.value) 个任务等待投递或重试" : "所有任务均已处理"
      ) {
        Toggle("只看失败", isOn: $onlyFailures)
          .toggleStyle(.switch)
          .controlSize(.small)
        Button("清空日志") {
          _ = try? model.database.writer.write { db in try ForwardLog.deleteAll(db) }
        }
        .disabled(logs.value.isEmpty)
      }
      .padding([.horizontal, .top], 24)
      .padding(.bottom, 12)

      if shown.isEmpty {
        EmptyStateView(
          symbol: "list.bullet.rectangle",
          title: onlyFailures ? "没有失败记录" : "暂无日志",
          message: "消息命中规则并推送后，结果会记录在这里。")
      } else {
        Table(shown) {
          TableColumn("") { log in
            Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
              .foregroundStyle(log.success ? Color.green : .red)
          }
          .width(20)
          TableColumn("时间") { log in
            Text(DateText.short(log.createdAt)).foregroundStyle(.secondary)
          }
          .width(min: 70, ideal: 90)
          TableColumn("通道") { log in Text(log.channelName) }
            .width(min: 80, ideal: 110)
          TableColumn("标题") { log in Text(log.title).lineLimit(1) }
          TableColumn("结果") { log in
            Text(log.httpStatus.map { "HTTP \($0) · \(log.detail)" } ?? log.detail)
              .lineLimit(1)
              .foregroundStyle(log.success ? Color.secondary : .red)
              .help(log.detail)
          }
          TableColumn("耗时") { log in
            Text("\(log.durationMs) ms").foregroundStyle(.secondary)
          }
          .width(60)
          TableColumn("") { log in
            if !log.success, let jobID = log.jobID {
              Button("重试") {
                Task { try? await model.queue.retry(jobID: jobID) }
              }
              .controlSize(.small)
            }
          }
          .width(50)
        }
      }
    }
  }
}
