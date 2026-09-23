import Foundation

enum AttentionRules {
    static func evaluate(_ state: RolloutState, settings: RuleSettings, now: Date) -> [AttentionItem] {
        var items: [AttentionItem] = []
        let current = state.events.filter { $0.turnID == state.turnID }
        func add(_ rule: String, _ title: String, _ explanation: String, _ advice: String,
                 event: TraceEvent? = nil, explanationIsSource: Bool = false, definite: Bool = false, time: Date? = nil, suffix: String = "") {
            items.append(AttentionItem(id: "\(state.threadID):\(state.turnID):\(rule):\(suffix)",
                threadID: state.threadID, rule: rule, title: title, explanation: explanation, advice: advice,
                timestamp: time ?? event?.timestamp ?? state.stateAt ?? now, evidenceID: event?.id,
                evidence: event?.source, definite: definite, explanationIsSource: explanationIsSource))
        }
        if state.state == .failed {
            let event = current.last(where: \.failed)
            add("failure", "本轮执行失败", event?.preview.isEmpty == false ? event!.preview : "运行时记录了失败的结束状态",
                "打开原任务，结合失败前的调用与错误信息处理；避免在原因未明时反复重试。", event: event, explanationIsSource: event?.preview.isEmpty == false, definite: true)
        }
        if state.state == .waiting {
            add("waiting", "等待你补充信息", "已记录输入请求，尚未观察到对应响应",
                "打开原任务查看问题并作答。", event: current.last(where: { $0.status == "requested" }), definite: true)
        }
        let tools = current.filter { $0.kind == .tool && $0.fingerprint != nil }
        if let last = tools.last, last.failed {
            let failures = tools.reversed().prefix { $0.failed && $0.title == last.title && $0.fingerprint == last.fingerprint }
            if failures.count >= max(settings.repeatCount, 2) {
                add("retries", "相同调用连续失败 \(failures.count) 次", "最近连续调用的工具、参数和返回内容相同",
                    "核对参数、权限和依赖是否发生变化，再决定是否继续重试。", event: last)
            }
        }
        let recent = tools.filter { !$0.isPolling && $0.readOnly && !$0.failed && now.timeIntervalSince($0.timestamp) <= Double(settings.repeatMinutes * 60) }
        let groups = Dictionary(grouping: recent, by: { $0.fingerprint ?? $0.id })
        for (_, events) in groups where events.count >= max(settings.repeatCount, 2) {
            let event = events.last!
            add("repeat", "重复读取 \(events.count) 次", "短时间内相同只读调用返回了相同内容，不代表已经形成死循环",
                "检查是否可以复用已有结果，或缩小下一次查询的范围。", event: event, suffix: event.fingerprint ?? "")
        }
        for event in current where event.outputBytes >= settings.largeOutputBytes && event.kind != .reasoning {
            add("large", "返回内容较大", "本次可见输出约 \(event.outputBytes / 1024) KiB；不等于当前上下文实际保留量",
                "优先过滤、聚合或分页返回内容；在上下文页查看随后用量变化。", event: event, suffix: event.id)
        }
        let samples = state.contexts.suffix(2)
        let wasHigh = state.alerts.contains { $0.rule == "context" && !$0.resolved }
        if let latest = samples.last, !state.pendingCompaction,
           (samples.count == 2 && samples.allSatisfy { ($0.ratio ?? -1) >= settings.contextHigh }
             || wasHigh && (latest.ratio ?? -1) >= settings.contextClear) {
            add("context", "最近观测的上下文占用偏高",
                "最近有效占用约 \(Int((latest.ratio ?? 0) * 100))%，采样后新增内容尚未计入",
                "查看大内容来源；后续输入减少重复材料，并在必要时主动整理交接摘要。", time: latest.timestamp)
        }
        if [.running, .waiting].contains(state.state), let last = state.lastEventAt,
           now.timeIntervalSince(last) >= Double(settings.silenceMinutes * 60) {
            add("quiet", "长时间没有新事件", "最近 \(Int(now.timeIntervalSince(last) / 60)) 分钟未观察到新增记录，不能据此判定卡死",
                "查看最后操作及原任务状态；若为构建、等待或长查询，可继续观察。", event: current.last, time: last)
        }
        let activeIDs = Set(items.map(\.id))
        let cutoff = now.addingTimeInterval(-30 * 86400)
        let resolved = state.alerts.filter { !activeIDs.contains($0.id) && $0.timestamp > cutoff }.map { item in
            var item = item; item.resolved = true; return item
        }
        return Array((items + resolved).prefix(100))
    }
}
