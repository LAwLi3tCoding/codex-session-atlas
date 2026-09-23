import SessionAtlasCore
import SwiftUI

struct SessionDetail: View {
    @ObservedObject var model: MonitorModel
    let session: SessionSummary
    @State private var eventSearch = ""
    @State private var kind = "全部"
    @State private var failuresOnly = false
    @State private var showResolved = false
    @State private var eventOrder = "最新在前"
    @State private var visibleEventCount = 100

    var body: some View {
        VStack(spacing: 0) {
            header
            switch model.detailTab {
            case "上下文": ContextCompositionView(model: model)
            case "轨迹": trajectory
            case "协作": collaborators
            default: overview
            }
        }.onChange(of: session.id) { _ in eventSearch = ""; kind = "全部"; failuresOnly = false; eventOrder = "最新在前"; visibleEventCount = 100 }
            .onChange(of: kind) { _ in visibleEventCount = 100 }
            .onChange(of: eventSearch) { _ in visibleEventCount = 100 }
            .onChange(of: failuresOnly) { _ in visibleEventCount = 100 }
            .onChange(of: eventOrder) { _ in visibleEventCount = 100 }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.title(session)).font(.system(size: 19, weight: .semibold))
                        .lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Label(session.workspace == "未知项目" ? L("未知项目") : session.workspaceName, systemImage: "folder").help(session.workspace)
                        Text("·")
                        Text(session.model == "未知模型" ? L("未知模型") : session.model)
                        Text(L("推理强度 \(session.effort)"))
                    }.font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary)
                    if let note = session.activityNote {
                        Text(Localization.diagnostic(note)).font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary)
                    }
                }
                Spacer()
                MonitorBadge(text: session.state.label, color: stateColor(session.state))
                Menu {
                    Button(L("在 Codex 打开任务")) { model.openTask(session.id) }
                    Button(L("复制任务标识")) { copyText(session.id) }
                    if let parent = session.parentID { Button(L("查看父任务")) { model.select(parent) } }
                } label: { Image(systemName: "ellipsis").frame(width: 38, height: 38).contentShape(Rectangle()) }.menuStyle(.borderlessButton).frame(width: 42)
            }
            HStack(spacing: 10) {
                tab("概览", icon: "rectangle.grid.1x2")
                tab("上下文", icon: "square.stack.3d.up")
                tab("轨迹", icon: "point.topleft.down.curvedto.point.bottomright.up")
                tab("协作", icon: "person.2")
                Spacer()
            }
        }.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 4)
            .frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            .background(MonitorStyle.paper)
    }
    private func tab(_ title: String, icon: String) -> some View {
        let selected = model.detailTab == title
        return Button { model.detailTab = title } label: {
            Label(L(title), systemImage: icon).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? MonitorStyle.ink : MonitorStyle.secondary)
                .frame(minHeight: 24).contentShape(Rectangle())
        }.buttonStyle(MonitorButtonStyle(selected: selected)).accessibilityLabel(L(title))
    }

    private var latestEvent: TraceEvent? {
        (model.events + model.observation.events).max { $0.timestamp < $1.timestamp }
    }
    private var overviewSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                activitySummary.frame(minWidth: 235, idealWidth: 235, maxWidth: .infinity)
                contextSummary.frame(minWidth: 235, idealWidth: 235, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 12) {
                activitySummary
                contextSummary
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(MonitorStyle.surface, in: RoundedRectangle(cornerRadius: 10))
    }
    private var activitySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("最近活动")).font(.system(size: 12, weight: .medium)).foregroundStyle(MonitorStyle.secondary)
                Spacer()
                Text(ageLabel(latestEvent?.timestamp ?? session.lastEventAt)).font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary)
            }
            Text(latestEvent.map(friendlyTool) ?? L("尚无执行记录"))
                .font(.system(size: 21, weight: .medium)).lineLimit(2)
            let preview = latestEvent.map { RecordExcerpt($0.localizedPreview()).text } ?? ""
            Text(preview.isEmpty ? L("有新的本地执行记录时，会自动显示在这里。") : preview)
                .font(.system(size: 12)).foregroundStyle(MonitorStyle.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button { model.detailTab = "轨迹" } label: {
                HStack { Text(L("查看轨迹")); Image(systemName: "arrow.right") }.font(.system(size: 12, weight: .medium))
            }.padding(.leading, -12)
        }.frame(height: 180, alignment: .topLeading)
    }
    private var contextSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("上下文使用率")).font(.system(size: 12, weight: .medium)).foregroundStyle(MonitorStyle.secondary)
                Spacer()
                Text(session.context.map { L("采样于 ") + clockLabel($0.timestamp) } ?? L("尚无采样"))
                    .font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.context?.ratio.map { "\(Int($0 * 100))%" } ?? L("未知"))
                    .font(.system(size: 28, weight: .medium)).monospacedDigit()
                if let point = session.context {
                    Text("\(tokenLabel(point.used)) / \(point.capacity.map(tokenLabel) ?? L("未知")) Token")
                        .font(.system(size: 12)).foregroundStyle(MonitorStyle.secondary)
                }
            }
            if let point = session.context, let ratio = point.ratio {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MonitorStyle.line)
                        Capsule().fill(ratio >= model.rules.contextHigh ? MonitorStyle.amber : MonitorStyle.ink)
                            .frame(width: geometry.size.width * min(max(ratio, 0), 1))
                    }
                }.frame(height: 4)
                Text(point.capacity.map { L("剩余约 \(tokenLabel(max(0, $0 - point.used))) Token") } ?? L("剩余容量未知"))
                    .font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary)
            } else {
                Text(L("运行时尚未提供窗口使用率。")).font(.system(size: 12)).foregroundStyle(MonitorStyle.secondary)
            }
            Spacer(minLength: 0)
            Button { model.detailTab = "上下文" } label: {
                HStack { Text(L("查看上下文")); Image(systemName: "arrow.right") }.font(.system(size: 12, weight: .medium))
            }.padding(.leading, -12)
        }.frame(height: 180, alignment: .topLeading)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewSummary
                attentionPanel
                MonitorPanel {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Text(L("最近的执行记录")).font(.headline)
                            Spacer()
                            Button(L("全部轨迹")) { model.detailTab = "轨迹" }.font(.caption)
                        }
                        let recent = model.events.filter { $0.kind != .reasoning }.prefix(6)
                        if recent.isEmpty { Text(L("任务有新的持久化记录时，会自动显示在这里。")).foregroundStyle(MonitorStyle.secondary).font(.callout) }
                        ForEach(Array(recent)) { event in
                            eventRow(event, compact: true)
                        }
                    }
                }
                if let note = session.dataNote { Label(Localization.diagnostic(note), systemImage: "info.circle").font(.caption).foregroundStyle(MonitorStyle.secondary) }
                Text(L("状态来自最近的本地记录。长时间没有新记录时，需要回到原任务确认；「本轮结束」不等于任务目标已完成。"))
                    .font(.caption).foregroundStyle(MonitorStyle.secondary)
            }.monitorDocument().id(model.language)
        }.background(MonitorStyle.canvas)
    }
    private var attentionPanel: some View {
        MonitorPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("关注事项")).font(.headline)
                    Spacer()
                    Button { showResolved.toggle() } label: {
                        Label(L("显示已解除"), systemImage: showResolved ? "checkmark.square.fill" : "square")
                    }.buttonStyle(MonitorButtonStyle(selected: showResolved)).font(.caption)
                }
                let alerts = model.observation.attention.filter { showResolved || !$0.resolved }
                if alerts.isEmpty {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle").foregroundStyle(MonitorStyle.teal)
                        Text(L("暂未发现需要处理的事项")).font(.callout)
                    }.padding(.vertical, 7)
                }
                ForEach(alerts) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.resolved ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(item.resolved ? MonitorStyle.teal : MonitorStyle.amber).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(L(item.title)).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                MonitorBadge(text: item.resolved ? L("已解除") : (item.definite ? L("已确认") : L("待核实")), color: MonitorStyle.amber)
                            }
                            Text(item.localizedExplanation()).font(.system(size: 12)).foregroundStyle(MonitorStyle.secondary)
                            Text(L(item.advice)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 14) {
                                Button(L("查看依据")) {
                                    if let event = (model.observation.events + model.events).first(where: { $0.id == item.evidenceID }) { model.inspect(event) }
                                    else { model.detailTab = item.rule == "context" ? "上下文" : "轨迹" }
                                }
                                Button(L("打开原任务")) { model.openTask(session.id) }
                                Spacer()
                                if !item.seen { Button(L("我已看过")) { model.markSeen(item.id) } }
                            }.font(.caption)
                        }
                    }.padding(.vertical, 14)
                }
            }
        }
    }

    private var filteredEvents: [TraceEvent] {
        let values = model.events.filter { event in
            (kind == "全部" || event.kind.label == kind) && (!failuresOnly || event.failed)
                && (eventSearch.isEmpty || (friendlyTool(event) + event.preview).localizedCaseInsensitiveContains(eventSearch))
        }
        switch eventOrder {
        case "最早在前": return values.sorted { $0.timestamp < $1.timestamp }
        case "输出最大": return values.sorted { $0.outputBytes > $1.outputBytes }
        case "耗时最长": return values.sorted { ($0.durationMs ?? -1) > ($1.durationMs ?? -1) }
        default: return values.sorted { $0.timestamp > $1.timestamp }
        }
    }
    private var trajectory: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("按时间查看执行过程，也可以筛选失败、较大输出或较长耗时。"))
                    .font(.system(size: 12)).foregroundStyle(MonitorStyle.secondary)
                MonitorPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(L("执行记录")).font(.system(size: 15, weight: .semibold))
                            Text(L("已加载 \(model.events.count) 条 · 匹配 \(filteredEvents.count) 条")).font(.caption).foregroundStyle(MonitorStyle.secondary)
                            Spacer()
                            Button { failuresOnly.toggle() } label: {
                                Label(L("失败 \(model.events.filter(\.failed).count)"), systemImage: "exclamationmark.circle")
                            }.buttonStyle(MonitorButtonStyle(tint: .red, selected: failuresOnly))
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Button(L("全部类型")) { kind = "全部" }.buttonStyle(MonitorButtonStyle(selected: kind == "全部"))
                                ForEach(TraceKind.allCases.filter { type in model.events.contains { $0.kind == type } }, id: \.self) { type in
                                    Button { kind = kind == type.label ? "全部" : type.label } label: {
                                        Label("\(L(type.label)) \(model.events.filter { $0.kind == type }.count)", systemImage: icon(type))
                                            .font(.system(size: 12, weight: .medium)).fixedSize()
                                    }.buttonStyle(MonitorButtonStyle(tint: kindColor(type), selected: kind == type.label))
                                }
                            }
                        }
                        HStack(spacing: 12) {
                            MonitorSearchField(placeholder: L("搜索记录"), text: $eventSearch)
                            Picker(L("排序"), selection: $eventOrder) {
                                ForEach(["最新在前", "最早在前", "输出最大", "耗时最长"], id: \.self) { Text(L($0)).tag($0) }
                            }.frame(width: model.language.resolved == .english ? 215 : 180).controlSize(.large)
                        }
                        DisclosureGroup(L("记录范围与说明")) {
                            VStack(alignment: .leading, spacing: 10) {
                                if let oldest = model.events.map(\.timestamp).min(), let latest = model.events.map(\.timestamp).max() {
                                    Text(L("已加载范围：\(timestampLabel(oldest)) — \(timestampLabel(latest))"))
                                }
                                Text(L("分类数量和排序仅针对已加载记录。工具记录可能合并调用与结果；未提供耗时或体积时保持未知。"))
                                HStack(spacing: 15) {
                                    Label(L("调用待返回"), systemImage: "arrow.up.right.square.fill").foregroundStyle(MonitorStyle.category(.toolCall))
                                    Label(L("工具已有记录"), systemImage: "arrow.down.left.square.fill").foregroundStyle(MonitorStyle.category(.toolResult))
                                    Label(L("明确失败"), systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                                }
                            }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption).foregroundStyle(MonitorStyle.secondary)
                    }
                }
                if let note = model.pageNote { Label(Localization.diagnostic(note), systemImage: "info.circle").font(.caption).foregroundStyle(MonitorStyle.amber) }
                MonitorPanel {
                    // LazyVStack enters a layout loop on macOS 26 when a short filter replaces these rows.
                    // Render the first 100 eagerly, then expand only on explicit user request.
                    VStack(alignment: .leading, spacing: 10) {
                        let matching = filteredEvents
                        let events = Array(matching.prefix(visibleEventCount))
                        if events.isEmpty { Text(L("没有匹配记录。可以调整类型、失败筛选或搜索，再读取更早内容。")).foregroundStyle(MonitorStyle.secondary).padding(.vertical, 15) }
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            VStack(alignment: .leading, spacing: 10) {
                                if ["最新在前", "最早在前"].contains(eventOrder), index == 0 || events[index - 1].turnID != event.turnID {
                                    HStack {
                                        Image(systemName: "bubble.left.and.bubble.right")
                                        Text(event.turnID.isEmpty ? L("轮次标识未提供") : L("轮次 \(event.turnID.prefix(8))"))
                                        Text("· \(timestampLabel(event.timestamp))")
                                        Spacer()
                                    }.font(.caption.weight(.medium)).foregroundStyle(MonitorStyle.secondary)
                                        .padding(.top, index == 0 ? 0 : 18).padding(.bottom, 4).padding(.horizontal, 12)
                                }
                                eventRow(event)
                            }
                        }
                        if matching.count > visibleEventCount {
                            Button(L("显示更多已加载记录（\(matching.count - visibleEventCount) 条）")) { visibleEventCount += 100 }
                        } else if model.hasMore {
                            Button { visibleEventCount += 100; model.more() } label: {
                                Text(model.loadingHistory ? L("正在读取…") : L("读取更早的记录")).frame(maxWidth: .infinity)
                            }.disabled(model.loadingHistory).padding(.top, 12)
                        }
                    }
                }
            }.monitorDocument().id(model.language)
        }.background(MonitorStyle.canvas)
    }
    private func eventRow(_ event: TraceEvent, compact: Bool = false) -> some View {
        let category = MonitorStyle.traceCategory(event)
        let details = [
            event.durationMs.map { String(format: L("%.2f 秒"), $0 / 1000) },
            event.outputBytes > 0 ? L("输出 ") + Int64(event.outputBytes).formatted(.byteCount(style: .binary).locale(AppLanguage.current.locale)) : nil,
            event.status == "requested" ? L("结果待记录") : nil
        ].compactMap { $0 }.joined(separator: " · ")
        return Button { model.inspect(event) } label: {
            MonitorRecordLabel(title: friendlyTool(event), preview: event.localizedPreview(),
                               category: category, label: event.kind.label, timestamp: event.timestamp,
                               metadata: compact ? "" : details, failed: event.failed, compact: compact)
        }.buttonStyle(MonitorButtonStyle(row: true))
    }
    private func kindColor(_ kind: TraceKind) -> Color {
        switch kind {
        case .user: MonitorStyle.category(.user)
        case .assistant: MonitorStyle.category(.assistant)
        case .tool: MonitorStyle.category(.toolResult)
        case .file: MonitorStyle.category(.environment)
        case .agent: MonitorStyle.category(.skills)
        case .compaction: MonitorStyle.category(.summary)
        default: MonitorStyle.category(.instructions)
        }
    }
    private var collaborators: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("谁在一起完成这个任务")).font(.system(size: 21, weight: .semibold, design: .default))
                Text(L("每个 Agent 有独立上下文。点击任务查看它自己的上下文内容和执行记录。")).font(.callout).foregroundStyle(MonitorStyle.secondary)
                if let parent = session.parentID { Button(L("查看父任务")) { model.select(parent) } }
                MonitorPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        let children = model.snapshot.sessions.filter { $0.parentID == session.id }
                        ForEach([session] + children) { agent in
                            Button { if agent.id != session.id { model.select(agent.id) } } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: agent.id == session.id ? "person.crop.square" : "arrow.turn.down.right")
                                        .foregroundStyle(MonitorStyle.accent).frame(width: 25)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(agent.nickname ?? model.title(agent)).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                        Text("\(agent.model == "未知模型" ? L("未知模型") : agent.model) · \(ageLabel(agent.lastEventAt))").font(.caption).foregroundStyle(MonitorStyle.secondary)
                                        if let point = agent.context { Text(L("上下文 \(point.ratio.map { "\(Int($0 * 100))%" } ?? L("未知")) · 采样于 \(clockLabel(point.timestamp))")).font(.caption).foregroundStyle(MonitorStyle.secondary) }
                                    }
                                    Spacer()
                                    MonitorBadge(text: agent.state.label, color: stateColor(agent.state))
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(MonitorButtonStyle(row: true))
                        }
                        if children.isEmpty { Text(L("没有记录到直接子任务。")).font(.caption).foregroundStyle(MonitorStyle.secondary).padding(.top, 8) }
                    }
                }
            }.monitorDocument().id(model.language)
        }.background(MonitorStyle.canvas)
    }
    private func icon(_ kind: TraceKind) -> String {
        switch kind {
        case .user: "person"
        case .assistant: "text.bubble"
        case .tool: "terminal"
        case .file: "doc.text"
        case .agent: "person.2"
        case .compaction: "arrow.triangle.2.circlepath"
        case .lifecycle: "circle.dotted"
        case .plan: "list.bullet"
        case .reasoning: "text.alignleft"
        case .unknown: "questionmark.circle"
        }
    }
}
