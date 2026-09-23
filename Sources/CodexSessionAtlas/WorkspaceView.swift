import SessionAtlasCore
import SwiftUI

private struct DisplaySession: Identifiable {
    let session: SessionSummary
    let depth: Int
    let childCount: Int
    let activityAt: Date
    var id: String { session.id }
}

struct MonitorWorkspace: View {
    @ObservedObject var model: MonitorModel
    @State private var scope = "全部会话"
    @State private var project: String?
    @State private var search = ""
    @State private var showSystem = false
    @AppStorage("sessionSortMode") private var sortMode = SessionSortMode.recentActivity
    @State private var expanded = Set<String>()
    @State private var showDetailOnCompact = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if geometry.size.width >= 950 || !showDetailOnCompact {
                        taskList.frame(width: geometry.size.width >= 950 ? 280 : nil)
                    }
                    if geometry.size.width >= 950 || showDetailOnCompact {
                        VStack(spacing: 0) {
                            if geometry.size.width < 950 {
                                HStack {
                                    Button { showDetailOnCompact = false } label: { Label("任务列表", systemImage: "chevron.left") }
                                    Spacer()
                                }.padding(12).background(MonitorStyle.paper)
                            }
                            if let session = model.selected {
                                SessionDetail(model: model, session: session)
                            } else {
                                VStack(spacing: 13) {
                                    Image(systemName: "rectangle.stack").font(.system(size: 34)).foregroundStyle(MonitorStyle.accent)
                                    Text("选一个任务，看看它的执行过程").font(.title3)
                                    Text("所有本地任务仍会持续监控。").foregroundStyle(MonitorStyle.secondary)
                                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .foregroundStyle(MonitorStyle.ink).tint(MonitorStyle.accent)
        .buttonStyle(MonitorButtonStyle())
        .background(MonitorStyle.canvas).preferredColorScheme(.light)
        .sheet(isPresented: $model.showSettings) { MonitorSettings(model: model) }
        .sheet(item: $model.detailEvent) { event in contentSheet(event) }
    }

    private var topbar: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Session Atlas").font(.system(size: 13, weight: .semibold))
                Text("会话 · 轨迹 · 上下文").font(.system(size: 10)).foregroundStyle(MonitorStyle.secondary)
            }
            Spacer(minLength: 0)
            Button { model.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("监控设置")
        }.padding(.leading, 18).padding(.trailing, 8).frame(height: 60)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 0) {
            topbar
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("任务").font(.system(size: 12, weight: .medium))
                    Text(model.snapshot.sessions.count.formatted()).font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary)
                    Spacer()
                    Menu {
                        Picker("排序", selection: $sortMode) {
                            ForEach(SessionSortMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                        }
                        Divider()
                        Toggle("显示系统任务", isOn: $showSystem)
                        Button(scope == "已归档" ? "返回全部任务" : "查看已归档任务") { scope = scope == "已归档" ? "全部会话" : "已归档" }
                    } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 36, height: 36).contentShape(Rectangle()) }.menuStyle(.borderlessButton).frame(width: 40)
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(MonitorStyle.secondary)
                    TextField("搜索任务、项目或模型", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                }.padding(10).background(MonitorStyle.paper, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(MonitorStyle.line))
                HStack(spacing: 5) {
                    scopeButton("全部", value: "全部会话")
                    scopeButton("最近活跃", value: "最近活跃")
                        .help("轮次尚未结束，且近 5 分钟有执行记录；不包含等待用户的任务。")
                    scopeButton("需关注", value: "待关注")
                    if scope == "已归档" { MonitorBadge(text: "已归档") }
                }
                Menu {
                    Button("全部项目") { project = nil }
                    ForEach(Array(Set(model.snapshot.sessions.map(\.workspace))).sorted(), id: \.self) { path in
                        Button(path) { project = path }
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(MonitorStyle.secondary)
                        Text(project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "全部项目").lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }.font(.system(size: 12)).foregroundStyle(MonitorStyle.secondary).frame(minHeight: 36).contentShape(Rectangle())
                }.menuStyle(.borderlessButton)
                Text("排序：\(sortMode.label)")
                    .font(.system(size: 10)).foregroundStyle(MonitorStyle.secondary)
                    .help("按整组最新活动排序，子任务活动也会让父任务上移。尚无执行记录时使用目录时间。可在右上角筛选菜单切换。")
            }.padding(.horizontal, 14).padding(.vertical, 10)
            let rows = displayedRows
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Text(model.snapshot.sessions.isEmpty ? "正在读取任务目录" : "没有匹配的任务").font(.headline)
                    Text(model.snapshot.diagnostics.first ?? "调整搜索或筛选条件。").font(.caption).foregroundStyle(MonitorStyle.secondary)
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(rows) { row in
                            HStack(alignment: .top, spacing: 4) {
                                if row.childCount > 0 {
                                    Button {
                                        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                                    } label: {
                                        Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 11, weight: .semibold)).frame(width: 32, height: 44).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("展开或收起子任务")
                                }
                                Button {
                                    model.select(row.id); showDetailOnCompact = true
                                } label: {
                                    TaskRow(session: row.session, title: model.title(row.session), children: row.childCount,
                                            activityAt: row.activityAt,
                                            selected: model.selectedID == row.id,
                                            contextOnly: scope == "最近活跃" && !row.session.isRecentlyActive).equatable()
                                }.buttonStyle(.plain)
                            }
                            .padding(.leading, CGFloat(min(row.depth, 3)) * 10)
                            .padding(.horizontal, 9)
                            .contextMenu {
                                Button("在 Codex 打开") { model.openTask(row.id) }
                                Button("复制任务标识") { copyText(row.id) }
                            }
                        }
                    }.padding(.vertical, 9)
                }
            }
            footer
        }.background(MonitorStyle.sidebar)
    }

    private func scopeButton(_ title: String, value: String) -> some View {
        Button { scope = value } label: {
            HStack(spacing: 4) {
                Text(title)
                if value == "待关注" {
                    Text("\(model.snapshot.sessions.filter { $0.attentionCount > 0 }.count)").monospacedDigit()
                }
            }.font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(MonitorButtonStyle(selected: scope == value))
    }
    private var displayedRows: [DisplaySession] {
        let sessions = model.snapshot.sessions
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let childMap = Dictionary(grouping: sessions.filter { $0.parentID != nil }, by: { $0.parentID! })
        var included = Set(sessions.filter { session in
            guard showSystem || !session.isSystem else { return false }
            guard project == nil || session.workspace == project else { return false }
            switch scope {
            case "最近活跃": guard session.isRecentlyActive else { return false }
            case "待关注": guard session.attentionCount > 0 else { return false }
            case "已归档": guard session.archived else { return false }
            default: break
            }
            return search.isEmpty || [model.title(session), session.workspace, session.model, session.nickname ?? "", session.id]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }.map(\.id))
        for id in included {
            var parent = byID[id]?.parentID; var seen = Set([id])
            while let value = parent, let node = byID[value], seen.insert(value).inserted {
                included.insert(value); parent = node.parentID
            }
        }
        let order = SessionListOrder(sessions.filter { included.contains($0.id) })
        func sorted(_ values: [SessionSummary]) -> [SessionSummary] { order.sorted(values, mode: sortMode) }
        var result: [DisplaySession] = []; var visited = Set<String>()
        func append(_ session: SessionSummary, depth: Int) {
            guard included.contains(session.id), visited.insert(session.id).inserted else { return }
            let children = (childMap[session.id] ?? []).filter { included.contains($0.id) }
            result.append(DisplaySession(session: session, depth: depth, childCount: children.count,
                                         activityAt: order.activity(for: session)))
            if expanded.contains(session.id) || !search.isEmpty || scope == "待关注" {
                for child in sorted(children) { append(child, depth: depth + 1) }
            }
        }
        for root in sorted(sessions.filter { $0.parentID == nil || !included.contains($0.parentID!) }) { append(root, depth: 0) }
        return result
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(model.snapshot.diagnostics.isEmpty ? MonitorStyle.teal : MonitorStyle.amber).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.snapshot.diagnostics.isEmpty ? "持续观测 · 本机只读" : "部分数据待恢复")
                    .help(model.snapshot.diagnostics.joined(separator: "\n"))
                if let time = model.snapshot.refreshedAt {
                    Text("更新于 \(clockLabel(time)) · v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("立即刷新")
        }.font(.system(size: 10)).foregroundStyle(MonitorStyle.secondary)
            .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 12)
    }
    private func contentSheet(_ event: TraceEvent) -> some View {
        let category = model.detailMaterial?.category ?? MonitorStyle.traceCategory(event)
        let code = [.toolCall, .toolResult].contains(category)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: MonitorStyle.symbol(category))
                    .font(.system(size: 18)).foregroundStyle(MonitorStyle.category(category))
                    .frame(width: 38, height: 38)
                    .background(MonitorStyle.category(category).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        CategoryBadge(category: category)
                        Text(timestampLabel(event.timestamp)).font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary)
                    }
                    Text(model.detailMaterial?.category == .user ? "用户输入" : friendlyTool(event))
                        .font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    if let material = model.detailMaterial {
                        Text((material.fromReplacement ? "压缩后保留" : "本阶段新增") + " · "
                             + (material.readable ? characterLabel(material.characters) : "正文不可读"))
                            .font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary)
                    } else if event.kind == .tool {
                        Text((event.durationMs.map { String(format: "%.2f 秒", $0 / 1000) } ?? "耗时未提供")
                             + " · " + (event.outputBytes > 0 ? "输出 " + ByteCountFormatter.string(fromByteCount: Int64(event.outputBytes), countStyle: .binary) : "输出体积未提供"))
                            .font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button { model.detailEvent = nil } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction).accessibilityLabel("关闭内容")
            }.padding(28)
            ScrollView {
                MonitorRecordBody(text: model.detailText, raw: model.rawDetail, code: code)
                    .padding(.horizontal, 28).padding(.vertical, 12)
            }
            DisclosureGroup("来源与记录信息") {
                VStack(alignment: .leading, spacing: 8) {
                    if let material = model.detailMaterial {
                        Text(material.category.explanation)
                    }
                    Text(event.source.path).textSelection(.enabled)
                    HStack {
                        if let offset = event.source.offset { Text("记录位置 \(offset)").monospacedDigit() }
                        Spacer()
                        Button("复制来源位置") { copyText(event.source.path + (event.source.offset.map { "\n记录字节位置: \($0)" } ?? "")) }
                    }
                }.font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary).padding(.top, 8)
            }.font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary)
                .padding(.horizontal, 28).padding(.top, 18)
            HStack(spacing: 6) {
                Button("正文") { model.rawDetail = false }
                    .buttonStyle(MonitorButtonStyle(selected: !model.rawDetail))
                Button("原始记录") { model.rawDetail = true }
                    .buttonStyle(MonitorButtonStyle(selected: model.rawDetail))
                    .disabled(model.detailMaterial?.readable == false)
                Spacer()
                if model.detailText.contains("本页结束") { Button("下一页") { model.nextDetailPage() } }
                Button { copyText(model.detailText) } label: { Label("复制内容", systemImage: "doc.on.doc") }
            }.font(.system(size: 12)).padding(20)
                .onChange(of: model.rawDetail) { _ in model.reloadDetail() }
        }.frame(minWidth: 620, idealWidth: 860, minHeight: 520, idealHeight: 700)
            .foregroundStyle(MonitorStyle.ink).background(MonitorStyle.paper)
            .tint(MonitorStyle.accent).buttonStyle(MonitorButtonStyle())
    }

}

private struct TaskRow: View, Equatable {
    let session: SessionSummary
    let title: String
    let children: Int
    let activityAt: Date
    let selected: Bool
    var contextOnly = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Text(session.parentID == nil ? title : (session.nickname ?? title))
                    .font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if session.attentionCount > 0 { Circle().fill(MonitorStyle.amber).frame(width: 6, height: 6).padding(.top, 4) }
            }
            HStack(spacing: 5) {
                Circle().fill(stateColor(session.state)).frame(width: 5, height: 5)
                Text(contextOnly ? "含活跃子任务" : session.state.label)
                Spacer()
                if let ratio = session.context?.ratio {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 9))
                    Text("\(Int(ratio * 100))%").monospacedDigit()
                }
            }.font(.system(size: 10)).foregroundStyle(MonitorStyle.secondary)
            HStack {
                Text(session.workspaceName).lineLimit(1)
                if children > 0 { Text("· \(children) 个子任务") }
                Spacer()
                Text(ageLabel(activityAt))
                    .help(children > 0 ? "该任务及筛选范围内子任务的最近活动：\(timestampLabel(activityAt))" : "最近活动：\(timestampLabel(activityAt))")
            }.font(.system(size: 10)).foregroundStyle(MonitorStyle.secondary.opacity(0.85))
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? MonitorStyle.selection : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .help(contextOnly ? "此父任务仅用于展示活跃子任务的归属关系。" : (session.activityNote ?? session.dataNote ?? ""))
    }
}
