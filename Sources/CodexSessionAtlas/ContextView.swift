import Charts
import SessionAtlasCore
import SwiftUI

struct ContextCompositionView: View {
    @ObservedObject var model: MonitorModel
    @State private var phaseID: UInt64?
    @State private var checkpointID: UInt64?
    @State private var category: ContextCategory?
    @State private var search = ""
    @State private var visibleCount = 50
    @State private var showUsage = false
    @State private var showReadingGuide = false
    @State private var intervalOnly = false
    @State private var ordering = "时间顺序"

    private var history: ContextHistory { model.contextHistory }
    private var phase: ContextPhase? { history.phases.first { $0.id == phaseID } ?? history.phases.last }
    private var checkpoint: ContextCheckpoint? {
        phase?.checkpoints.first { $0.id == checkpointID } ?? phase?.checkpoints.last
    }
    private var change: ContextChange? { checkpoint.flatMap { phase?.change(at: $0.id) } }
    private var materials: [ContextMaterial] { phase?.materials(through: checkpointID) ?? [] }
    private var filtered: [ContextMaterial] {
        let values = (intervalOnly ? change?.materials ?? [] : materials).filter {
            (category == nil || $0.category == category)
                && (search.isEmpty || ($0.title + $0.preview).localizedCaseInsensitiveContains(search))
        }
        switch ordering {
        case "文本最长": return values.sorted { $0.characters == $1.characters ? $0.recordOffset < $1.recordOffset : $0.characters > $1.characters }
        case "最新在前": return values.sorted { $0.recordOffset > $1.recordOffset }
        default: return values
        }
    }
    private var categories: [ContextCategory] { ContextCategory.allCases.filter { c in materials.contains { $0.category == c } } }
    private var totalCharacters: Int { materials.reduce(0) { $0 + $1.characters } }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("查看窗口使用率，追查已记录的内容及其变化。")
                                .font(.system(size: 12)).foregroundStyle(MonitorStyle.secondary)
                        }
                        Spacer()
                        Button { showReadingGuide.toggle() } label: {
                            Label("这些数字怎么看", systemImage: "questionmark.circle").font(.system(size: 12))
                        }.buttonStyle(MonitorButtonStyle(selected: showReadingGuide))
                    }
                    if showReadingGuide {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("上下文使用率：运行时报告的已用 Token ÷ 窗口容量，是最近采样时的容量使用情况。")
                            Text("已记录内容的文本占比：某类可读字符数 ÷ 所选范围全部可读字符数，不是 Token 占比。")
                            Text("Token 消耗：多次请求的用量统计。已有输入可能重复计入，因此累计值可大于窗口容量。")
                        }.font(.system(size: 12)).foregroundStyle(MonitorStyle.secondary).lineSpacing(3)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(MonitorStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !history.complete && !history.phases.isEmpty {
                        Label("历史内容尚未读完（\(Int(Double(history.readBytes) / Double(max(history.totalBytes, 1)) * 100))%）。阶段、采样和组成暂时只覆盖已读取部分。", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 12)).foregroundStyle(MonitorStyle.amber)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(MonitorStyle.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if let phase {
                        phaseRail
                        capacityPanel(phase)
                        changePanel
                        compositionPanel(phase)
                        HStack(spacing: 10) {
                            Button { intervalOnly = false; ordering = "文本最长"; category = nil; search = ""; reader.scrollTo("materials", anchor: .top) } label: {
                                Label("查看最长内容", systemImage: "chart.bar.xaxis")
                            }
                            if change != nil {
                                Button { intervalOnly = true; ordering = "时间顺序"; category = nil; search = ""; reader.scrollTo("materials", anchor: .top) } label: {
                                    Label("看两次采样间新增", systemImage: "plus.rectangle.on.rectangle")
                                }
                            }
                            Spacer(minLength: 0)
                        }.font(.callout)
                        materialPanel.id("materials")
                        usagePanel
                    } else {
                        MonitorPanel {
                            VStack(alignment: .leading, spacing: 10) {
                                if model.contextLoading { ProgressView().controlSize(.small) }
                                Text(model.contextLoading ? "正在读取上下文内容" : "尚未读到上下文内容").font(.headline)
                                Text(history.note ?? "读取本地消息和压缩记录后，这里会显示各阶段包含的内容。").foregroundStyle(MonitorStyle.secondary)
                                Button("重新读取") { model.loadComposition() }
                            }
                        }
                    }
                    if !history.complete && !history.phases.isEmpty {
                        HStack {
                            ProgressView(value: Double(history.readBytes), total: Double(max(history.totalBytes, 1))).frame(width: 130)
                            Text("已读取 \(Int(Double(history.readBytes) / Double(max(history.totalBytes, 1)) * 100))% 的本地记录")
                            Spacer()
                            Button("继续读取") { model.loadComposition() }.disabled(model.contextLoading)
                        }.font(.caption).foregroundStyle(MonitorStyle.secondary)
                    }
                    if let note = history.note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(MonitorStyle.amber) }
                }.monitorDocument()
            }
        }
        .background(MonitorStyle.canvas)
        .onAppear { model.loadComposition() }
        .onChange(of: model.selectedID) { _ in
            phaseID = nil; checkpointID = nil; category = nil; search = ""; visibleCount = 50
            intervalOnly = false; ordering = "时间顺序"; model.loadComposition()
        }
        .onChange(of: search) { _ in visibleCount = 50 }
        .onChange(of: checkpointID) { value in
            if value != nil { phaseID = phase?.id }
            visibleCount = 50
        }
    }

    private var phaseRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选择压缩阶段").font(.headline)
                Spacer()
                Text("\(history.phases.count) 个阶段 · 每次压缩开始一个新阶段").font(.caption).foregroundStyle(MonitorStyle.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 10) {
                    ForEach(history.phases) { value in
                        Button {
                            phaseID = value.id; checkpointID = nil; category = nil; visibleCount = 50; intervalOnly = false
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: value.number == 0 ? "tray" : "archivebox")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(value.title).font(.system(size: 13, weight: .semibold))
                                    Text("\(clockLabel(value.startedAt)) · \(value.materials.count) 项内容").font(.system(size: 11))
                                }
                                if value.id == history.phases.last?.id { Text(history.complete ? "当前" : "已读末段").font(.caption.weight(.semibold)) }
                            }.frame(minHeight: 46).contentShape(Rectangle())
                        }.buttonStyle(MonitorButtonStyle(selected: phase?.id == value.id))
                    }
                }.padding(2)
            }
        }
    }

    private func capacityPanel(_ phase: ContextPhase) -> some View {
        MonitorPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("上下文使用率").font(.headline)
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Text(checkpoint?.ratio.map { "\(Int($0 * 100))%" } ?? "未知")
                                .font(.system(size: 34, weight: .semibold, design: .default)).monospacedDigit()
                            Text("已用").font(.callout).foregroundStyle(MonitorStyle.secondary)
                            if let point = checkpoint {
                                Text("\(tokenLabel(point.used)) / \(point.capacity.map(tokenLabel) ?? "未知")")
                                    .font(.callout).monospacedDigit()
                            }
                        }
                        if let point = checkpoint, let capacity = point.capacity, capacity > 0 {
                            Text("按本次采样，剩余 \(tokenLabel(max(0, capacity - point.used))) Token")
                                .font(.caption).foregroundStyle(MonitorStyle.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 7) {
                        MonitorBadge(text: checkpointID == nil ? (history.complete ? "最近采样" : "已读部分的最近采样") : "正在回看", color: MonitorStyle.accent)
                        if let point = checkpoint {
                            Text(timestampLabel(point.timestamp)).font(.caption).monospacedDigit()
                            Text(point.model).font(.caption).foregroundStyle(MonitorStyle.secondary).lineLimit(1)
                        }
                    }
                }
                if !phase.checkpoints.isEmpty { capacityChart(phase) }
                HStack(spacing: 8) {
                    Text("查看到").font(.caption).foregroundStyle(MonitorStyle.secondary)
                    Picker("查看时刻", selection: $checkpointID) {
                        Text("最新记录（持续更新）").tag(nil as UInt64?)
                        ForEach(phase.checkpoints.reversed()) { point in
                            Text("\(clockLabel(point.timestamp)) · \(tokenLabel(point.used)) Token").tag(Optional(point.id))
                        }
                    }.labelsHidden().controlSize(.large).frame(maxWidth: 290)
                    Button { stepCheckpoint(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(!canStep(-1)).accessibilityLabel("上一采样")
                    Button { stepCheckpoint(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(!canStep(1)).accessibilityLabel("下一采样")
                    Spacer(minLength: 0)
                    if checkpointID != nil { Button("回到最新") { checkpointID = nil; intervalOnly = false } }
                }
                Text("点击曲线可回看。使用率来自运行时采样；下方内容来自本地日志，可能含当次输出，不等于模型请求的完整输入。")
                    .font(.caption).foregroundStyle(MonitorStyle.secondary)
            }
        }
    }

    private func capacityChart(_ phase: ContextPhase) -> some View {
        Chart {
            ForEach(phase.checkpoints) { point in
                if let ratio = point.ratio {
                    LineMark(x: .value("时间", point.timestamp), y: .value("占用 %", ratio * 100),
                             series: .value("模型与容量", "\(point.model):\(point.capacity ?? 0)"))
                        .foregroundStyle(MonitorStyle.accent).lineStyle(StrokeStyle(lineWidth: 2.5))
                }
            }
            if let point = checkpoint, let ratio = point.ratio {
                RuleMark(x: .value("所选时刻", point.timestamp)).foregroundStyle(MonitorStyle.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                PointMark(x: .value("时间", point.timestamp), y: .value("占用 %", ratio * 100))
                    .foregroundStyle(MonitorStyle.accent).symbolSize(65)
            }
        }
        .chartYScale(domain: 0...max(100, (phase.checkpoints.compactMap(\.ratio).max() ?? 1) * 100))
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { value in
            AxisGridLine(); AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%") } }
        } }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
                        let x = gesture.location.x - geometry[proxy.plotAreaFrame].origin.x
                        guard let time: Date = proxy.value(atX: x),
                              let nearest = phase.checkpoints.min(by: { abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time)) }) else { return }
                        checkpointID = nearest.id; visibleCount = 50
                    })
            }
        }
        .frame(height: 145).accessibilityLabel("上下文占用曲线；也可通过查看时刻菜单或前后按钮选择采样")
    }
    private func canStep(_ delta: Int) -> Bool {
        guard let points = phase?.checkpoints, let point = checkpoint, let index = points.firstIndex(where: { $0.id == point.id }) else { return false }
        return points.indices.contains(index + delta)
    }
    private func stepCheckpoint(_ delta: Int) {
        guard canStep(delta), let points = phase?.checkpoints, let point = checkpoint,
              let index = points.firstIndex(where: { $0.id == point.id }) else { return }
        checkpointID = points[index + delta].id; visibleCount = 50
    }

    private var changePanel: some View {
        MonitorPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("相邻采样之间发生了什么", systemImage: "arrow.left.arrow.right").font(.headline)
                    Spacer()
                    if let change { Text("\(clockLabel(change.previous.timestamp)) → \(clockLabel(change.current.timestamp))").font(.caption).monospacedDigit() }
                }
                if let change {
                    HStack(alignment: .top, spacing: 24) {
                        metric("占用变化", value: change.tokenDelta.map { ($0 > 0 ? "+" : "") + tokenLabel($0) + " Token" } ?? "不可直接比较")
                        metric("新增记录", value: "\(change.materials.count) 项")
                        metric("新增可读文本", value: characterLabel(change.materials.reduce(0) { $0 + $1.characters }))
                    }
                    Text(change.tokenDelta == nil
                         ? "模型或窗口容量不同，暂不计算 Token 差值；内容仍按两次采样之间的日志位置列出。"
                         : "这些内容在两次采样之间出现，可用于追查变化；字符量不能换算为精确 Token 贡献。")
                        .font(.caption).foregroundStyle(MonitorStyle.secondary)
                } else {
                    Text("这是本阶段的首个采样，或尚无采样；没有同阶段的前一次记录可供比较。")
                        .font(.callout).foregroundStyle(MonitorStyle.secondary)
                }
            }
        }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(MonitorStyle.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compositionPanel(_ phase: ContextPhase) -> some View {
        MonitorPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已记录内容的文本占比").font(.headline)
                        Text("\(materials.count) 项 · \(characterLabel(totalCharacters)) · \(materials.filter { !$0.readable }.count) 项正文不可读")
                            .font(.caption).foregroundStyle(MonitorStyle.secondary)
                    }
                    Spacer()
                    if category != nil { Button("清除分类筛选") { category = nil } }
                }
                if totalCharacters > 0 {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(categories, id: \.self) { type in
                                let count = materials.filter { $0.category == type }.reduce(0) { $0 + $1.characters }
                                if count > 0 {
                                    Rectangle().fill(MonitorStyle.category(type))
                                        .frame(width: geometry.size.width * Double(count) / Double(totalCharacters))
                                        .overlay(Rectangle().stroke(.white, lineWidth: 1))
                                        .help("\(type.label) · \(percentLabel(count, total: totalCharacters)) · \(characterLabel(count))")
                                }
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 6))
                    }.frame(height: 16)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .leading)], spacing: 10) {
                    ForEach(categories, id: \.self) { type in categoryButton(type) }
                }
                HStack(spacing: 16) {
                    Label("压缩后保留 \(materials.filter(\.fromReplacement).count) 项", systemImage: "archivebox")
                    Label("本阶段新增 \(materials.filter { !$0.fromReplacement }.count) 项", systemImage: "plus.circle")
                }.font(.caption).foregroundStyle(MonitorStyle.secondary)
                Text("点击类别查看内容。占比按可读字符计算，不是 Token 占比。")
                    .font(.caption).foregroundStyle(MonitorStyle.secondary)
                if phase.number > 0 {
                    Label(phase.hasReplacement ? "保留内容来自压缩后记录的消息集合；加密摘要无法读取正文。"
                          : "日志没有提供压缩后的完整消息集合，只显示已知摘要与新增内容。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(MonitorStyle.amber)
                }
                Text("覆盖范围：本地日志可见内容。未记录的系统提示、工具定义、服务端裁剪与加密正文不在可读统计中。")
                    .font(.caption).foregroundStyle(MonitorStyle.secondary)
            }
        }
    }
    private func categoryButton(_ type: ContextCategory) -> some View {
        let values = materials.filter { $0.category == type }
        let count = values.reduce(0) { $0 + $1.characters }
        let selected = category == type
        return Button { category = selected ? nil : type; intervalOnly = false; visibleCount = 50 } label: {
            HStack(spacing: 10) {
                Image(systemName: MonitorStyle.symbol(type)).font(.system(size: 17))
                    .foregroundStyle(MonitorStyle.category(type)).frame(width: 23)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(type.label).font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 4)
                        Text(values.allSatisfy { !$0.readable } ? "不可读" : percentLabel(count, total: totalCharacters))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                    Text("\(values.count) 项 · \(values.allSatisfy { !$0.readable } ? "正文不可读" : characterLabel(count))")
                        .font(.system(size: 11)).foregroundStyle(MonitorStyle.secondary)
                }
            }.frame(maxWidth: .infinity, minHeight: 43, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(MonitorButtonStyle(tint: MonitorStyle.category(type), selected: selected, row: true))
            .help(type.explanation)
            .accessibilityLabel("\(type.label)，\(values.count) 项，\(characterLabel(count))，\(selected ? "已选中" : "点击筛选")")
    }

    private var materialPanel: some View {
        MonitorPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("内容明细").font(.headline)
                    Text("\(filtered.count) 项匹配").font(.caption).foregroundStyle(MonitorStyle.secondary)
                    Spacer()
                    Picker("排序", selection: $ordering) {
                        Text("时间顺序").tag("时间顺序")
                        Text("最新在前").tag("最新在前")
                        Text("文本最长").tag("文本最长")
                    }.frame(width: 175).controlSize(.large)
                }
                HStack(spacing: 8) {
                    Button("截至所选时刻") { intervalOnly = false; visibleCount = 50 }
                        .buttonStyle(MonitorButtonStyle(selected: !intervalOnly))
                    Button("两次采样间新增") { intervalOnly = true; visibleCount = 50 }
                        .buttonStyle(MonitorButtonStyle(selected: intervalOnly)).disabled(change == nil)
                    Spacer(minLength: 0)
                    MonitorSearchField(placeholder: "搜索内容", text: $search).frame(maxWidth: 230)
                }
                if let category {
                    HStack {
                        CategoryBadge(category: category)
                        Button("清除筛选") { self.category = nil; search = "" }
                        Spacer()
                    }
                    Text(category.explanation).font(.system(size: 12)).foregroundStyle(MonitorStyle.secondary)
                }
                if filtered.isEmpty { Text("这个范围没有匹配内容。可以清除分类、搜索，或改看截至所选时刻的全部内容。").font(.callout).foregroundStyle(MonitorStyle.secondary).padding(.vertical, 12) }
                LazyVStack(spacing: 10) {
                    ForEach(Array(filtered.prefix(visibleCount))) { material in
                        materialRow(material)
                    }
                }
                if filtered.count > visibleCount {
                    Button { visibleCount += 50 } label: { Text("再显示 50 条").frame(maxWidth: .infinity) }
                }
            }
        }
    }
    private func materialRow(_ material: ContextMaterial) -> some View {
        Button { model.inspect(material) } label: {
            MonitorRecordLabel(title: material.category == .user ? "用户输入" : material.title,
                               preview: material.preview, category: material.category,
                               label: material.category.label, timestamp: material.timestamp,
                               metadata: (material.fromReplacement ? "压缩后保留" : "本阶段新增") + " · "
                                   + (material.readable ? characterLabel(material.characters) : "正文不可读"))
        }.buttonStyle(MonitorButtonStyle(row: true))
    }

    private var usagePanel: some View {
        MonitorPanel {
            VStack(alignment: .leading, spacing: 14) {
                Button { showUsage.toggle() } label: {
                    HStack {
                        Label("Token 消耗", systemImage: "sum").font(.headline)
                        Spacer()
                        Image(systemName: showUsage ? "chevron.up" : "chevron.down")
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(MonitorButtonStyle(row: true))
                if showUsage {
                    Text("以下是任务最新用量，不随上方历史时刻切换。每次请求都可能再次计入已有输入，因此累计值可能大于窗口容量。")
                        .font(.caption).foregroundStyle(MonitorStyle.secondary)
                    HStack(alignment: .top, spacing: 20) {
                        usage("最近一次请求", model.observation.usage.last?.tokens)
                        usage("当前轮次", model.observation.turnUsage)
                        usage("任务累计", model.observation.cumulative)
                    }
                    Text("缓存输入属于输入，推理输出属于输出，不能再次相加；消耗不是费用估算。")
                        .font(.caption).foregroundStyle(MonitorStyle.secondary)
                }
            }
        }
    }
    private func usage(_ label: String, _ tokens: TokenBreakdown?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.caption).foregroundStyle(MonitorStyle.secondary)
            Text(tokens.map { tokenLabel($0.total) + " Token" } ?? "未知").font(.title3).monospacedDigit()
            if let tokens {
                Label("输入 \(tokenLabel(tokens.input))", systemImage: "arrow.down.circle.fill").foregroundStyle(MonitorStyle.category(.user))
                Text("其中缓存 \(tokenLabel(tokens.cached))").foregroundStyle(MonitorStyle.secondary)
                Label("输出 \(tokenLabel(tokens.output))", systemImage: "arrow.up.circle.fill").foregroundStyle(MonitorStyle.category(.assistant))
                Text("其中推理 \(tokenLabel(tokens.reasoning))").foregroundStyle(MonitorStyle.secondary)
            }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}
