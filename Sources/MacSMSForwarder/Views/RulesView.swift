import ForwarderCore
import GRDB
import SwiftUI

/// 转发规则页
struct RulesView: View {
  @EnvironmentObject private var model: AppModel
  /// 正在编辑的规则（新建时 id 为 nil）
  @State private var editing: ForwardRule?

  @StateObject private var rules = DBObserver<[ForwardRule]>(initial: []) { db in
    try ForwardRule.order(Column("priority"), Column("id")).fetchAll(db)
  }
  @StateObject private var channels = DBObserver<[ForwardChannelRecord]>(initial: []) { db in
    try ForwardChannelRecord.order(Column("id")).fetchAll(db)
  }

  var body: some View {
    VStack(spacing: 0) {
      PageHeader(title: "转发规则", subtitle: "收到的消息按优先级逐条匹配，命中后推送到所选通道") {
        Button {
          editing = ForwardRule(
            name: "新规则", channelIDs: channels.value.compactMap(\.id))
        } label: {
          Label("新建规则", systemImage: "plus")
        }
      }
      .padding([.horizontal, .top], 24)
      .padding(.bottom, 12)

      if rules.value.isEmpty {
        EmptyStateView(
          symbol: "line.3.horizontal.decrease.circle",
          title: "还没有规则",
          message: "新建一条不带条件的规则即可转发所有消息；也可以只转发含「验证码」的消息。")
      } else {
        List {
          ForEach(rules.value) { rule in
            RuleRow(rule: rule, channels: channels.value)
              .contentShape(Rectangle())
              .onTapGesture(count: 2) { editing = rule }
              .contextMenu {
                Button("编辑") { editing = rule }
                Button("删除", role: .destructive) { delete(rule) }
              }
          }
        }
        .listStyle(.inset)
      }
    }
    .sheet(item: $editing) { rule in
      RuleEditor(rule: rule, channels: channels.value)
        .environmentObject(model)
    }
  }

  private func delete(_ rule: ForwardRule) {
    _ = try? model.database.writer.write { db in try rule.delete(db) }
  }
}

/// 规则行
private struct RuleRow: View {
  @EnvironmentObject private var model: AppModel
  let rule: ForwardRule
  let channels: [ForwardChannelRecord]

  /// 条件摘要，例如「内容 包含 验证码」
  private var summary: String {
    guard !rule.conditions.isEmpty else { return "所有收到的消息" }
    let joiner = rule.matchMode == .all ? " 且 " : " 或 "
    return rule.conditions.map { c in
      c.field.isBoolean ? "\(c.field.title)：\(c.op.title)" : "\(c.field.title) \(c.op.title)「\(c.value)」"
    }.joined(separator: joiner)
  }

  private var channelNames: String {
    let names = rule.channelIDs.compactMap { id in channels.first { $0.id == id }?.name }
    return names.isEmpty ? "未选择通道" : names.joined(separator: "、")
  }

  var body: some View {
    HStack(spacing: 12) {
      Toggle(
        "",
        isOn: Binding(
          get: { rule.enabled },
          set: { value in
            var updated = rule
            updated.enabled = value
            _ = try? model.database.writer.write { db in try updated.update(db) }
          })
      )
      .toggleStyle(.switch)
      .controlSize(.small)
      .labelsHidden()

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(rule.name).font(.body.weight(.medium))
          Tag(text: "优先级 \(rule.priority)")
          if rule.stopAfterMatch { Tag(text: "命中后停止", color: .orange) }
        }
        Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        Label(channelNames, systemImage: "paperplane")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.vertical, 6)
    .opacity(rule.enabled ? 1 : 0.55)
  }
}

/// 规则编辑表单
struct RuleEditor: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State var rule: ForwardRule
  let channels: [ForwardChannelRecord]
  @State private var testResult: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(rule.id == nil ? "新建规则" : "编辑规则")
        .font(.title3.weight(.semibold))
        .padding(20)

      Form {
        Section {
          TextField("名称", text: $rule.name)
          Stepper("优先级：\(rule.priority)", value: $rule.priority, in: 0...999)
          Toggle("命中后不再匹配后续规则", isOn: $rule.stopAfterMatch)
        }

        Section {
          Picker("满足", selection: $rule.matchMode) {
            Text("全部条件").tag(MatchMode.all)
            Text("任一条件").tag(MatchMode.any)
          }
          .pickerStyle(.segmented)
          ForEach($rule.conditions) { $condition in
            ConditionRow(condition: $condition) {
              rule.conditions.removeAll { $0.id == condition.id }
            }
          }
          Button {
            rule.conditions.append(RuleCondition(field: .text, op: .contains))
          } label: {
            Label("添加条件", systemImage: "plus.circle")
          }
          .buttonStyle(.borderless)
        } header: {
          Text("条件")
        } footer: {
          Text("不添加条件则匹配所有收到的消息").font(.caption).foregroundStyle(.secondary)
        }

        Section("推送到") {
          if channels.isEmpty {
            Text("还没有通道，请先在「转发通道」中添加").foregroundStyle(.secondary)
          }
          ForEach(channels) { channel in
            Toggle(
              isOn: Binding(
                get: { rule.channelIDs.contains(channel.id ?? -1) },
                set: { on in
                  guard let id = channel.id else { return }
                  if on {
                    rule.channelIDs.append(id)
                  } else {
                    rule.channelIDs.removeAll { $0 == id }
                  }
                })
            ) {
              Label(channel.name, systemImage: channel.type.symbol)
            }
          }
        }

        Section {
          TextField("标题模板", text: $rule.titleTemplate)
          TextField("正文模板", text: $rule.bodyTemplate, axis: .vertical)
            .lineLimit(2...5)
        } header: {
          Text("推送模板")
        } footer: {
          VariableHelp()
        }

        if let testResult {
          Section("测试结果") {
            Text(testResult).font(.callout).textSelection(.enabled)
          }
        }
      }
      .formStyle(.grouped)

      HStack {
        Button("用最近一条消息测试") { test() }
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("保存") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding(20)
    }
    .frame(width: 560, height: 640)
  }

  /// 用最近收到的一条消息检验规则是否命中，并预览渲染结果
  private func test() {
    let latest = try? model.database.writer.read { db in
      try StoredMessage
        .filter(Column("direction") == MessageDirection.incoming.rawValue)
        .order(Column("id").desc)
        .fetchOne(db)
    }
    guard let latest else {
      testResult = "还没有收到过消息，无法测试"
      return
    }
    let hit = RuleEngine.matches(rule, message: latest)
    let vars = RuleEngine.variables(for: latest)
    let title = TemplateRenderer.render(rule.titleTemplate, variables: vars)
    let body = TemplateRenderer.render(rule.bodyTemplate, variables: vars)
    testResult = """
      消息：\(latest.handle)：\(latest.text.prefix(60))
      结果：\(hit ? "✅ 命中" : "❌ 未命中")
      标题：\(title)
      正文：\(body)
      """
  }

  private func save() {
    var record = rule
    do {
      try model.database.writer.write { db in try record.save(db) }
      dismiss()
    } catch {
      testResult = "保存失败：\(error.localizedDescription)"
    }
  }
}

/// 单个条件编辑行
private struct ConditionRow: View {
  @Binding var condition: RuleCondition
  var onDelete: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Picker("", selection: $condition.field) {
        ForEach(RuleField.allCases) { field in
          Text(field.title).tag(field)
        }
      }
      .labelsHidden()
      .frame(width: 100)
      .onChange(of: condition.field) { _, field in
        // 切换字段类型时自动修正运算符
        let allowed = field.isBoolean ? RuleOperator.boolOperators : RuleOperator.textOperators
        if !allowed.contains(condition.op) { condition.op = allowed[0] }
      }

      Picker("", selection: $condition.op) {
        ForEach(condition.field.isBoolean ? RuleOperator.boolOperators : RuleOperator.textOperators) {
          op in
          Text(op.title).tag(op)
        }
      }
      .labelsHidden()
      .frame(width: 100)

      if !condition.field.isBoolean {
        TextField("值", text: $condition.value)
      } else {
        Spacer()
      }

      Button(action: onDelete) {
        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
    }
  }
}

/// 模板变量说明
struct VariableHelp: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("可用变量：").font(.caption.weight(.medium))
      ForEach(TemplateRenderer.availableVariables, id: \.name) { item in
        Text("{{\(item.name)}}  \(item.description)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
    }
    .textSelection(.enabled)
  }
}
