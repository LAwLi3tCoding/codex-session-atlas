import CryptoKit
import Foundation

enum ObservationParser {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let text = value as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
    static func number(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
    static func tokens(_ value: Any?) -> TokenBreakdown? {
        guard let object = value as? [String: Any] else { return nil }
        return TokenBreakdown(input: number(object["input_tokens"] ?? object["inputTokens"]),
            cached: number(object["cached_input_tokens"] ?? object["cachedInputTokens"]),
            output: number(object["output_tokens"] ?? object["outputTokens"]),
            reasoning: number(object["reasoning_output_tokens"] ?? object["reasoningOutputTokens"]),
            total: number(object["total_tokens"] ?? object["totalTokens"]))
    }
    static func text(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let list = value as? [Any] { return list.map(text).filter { !$0.isEmpty }.joined(separator: "\n") }
        if let object = value as? [String: Any] {
            return text(object["text"] ?? object["message"] ?? object["content"] ?? object["summary"])
        }
        return ""
    }
    static func json(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func summary(_ value: String, limit: Int = 180) -> String {
        String(value.replacingOccurrences(of: "\0", with: "").prefix(limit))
    }
    static func item(_ object: [String: Any], threadID: String, turnID: String, timestamp: Date,
                     source: SourceReference, started: Date? = nil, ended: Date? = nil) -> TraceEvent {
        let type = (object["type"] as? String ?? "").lowercased()
        let kind: TraceKind
        var title = ""
        var preview = ""
        var output = ""
        switch type {
        case "usermessage": kind = .user; title = "用户输入"; preview = text(object["content"])
        case "agentmessage":
            kind = .assistant
            title = (object["phase"] as? String) == "commentary" ? "执行进展" : "助手回复"
            preview = text(object["text"] ?? object["content"])
        case "reasoning": kind = .reasoning; title = "可见推理摘要"; preview = text(object["summary_text"] ?? object["summary"])
        case "commandexecution":
            kind = .tool; title = "命令执行"
            preview = text(object["command"])
            output = text(object["aggregatedOutput"] ?? object["aggregated_output"] ?? object["stdout"])
        case "mcptoolcall", "dynamictoolcall", "functioncalloutput":
            kind = .tool; title = text(object["tool"] ?? object["name"])
            if title.isEmpty { title = "工具调用" }
            preview = json(object["arguments"])
            output = text(object["result"] ?? object["contentItems"] ?? object["output"])
            if output.isEmpty { output = json(object["result"] ?? object["error"]) }
        case "filechange":
            kind = .file; title = "文件修改"; preview = json(object["changes"]); output = preview
        case "collabtoolcall", "collabagenttoolcall", "subagentactivity":
            kind = .agent; title = "子 Agent 活动"; preview = json(object["agentsStates"] ?? object["agentStatus"] ?? object["prompt"])
        case "contextcompaction": kind = .compaction; title = "上下文压缩"
        case "plan": kind = .plan; title = "执行计划"; preview = text(object["text"] ?? object["steps"])
        case "websearch": kind = .tool; title = "搜索网页"; preview = text(object["query"]); output = json(object["results"])
        case "imageview": kind = .tool; title = "查看图片"; preview = text(object["path"])
        case "extension":
            kind = .tool; title = text(object["kind"])
            if title.isEmpty { title = "扩展调用" }
            preview = text(object["query"] ?? object["text"] ?? object["path"]); output = json(object["results"])
        default: kind = .unknown; title = text(object["type"]); preview = "未识别的事件，保留源记录"
        }
        var status = (object["status"] as? String ?? "completed").lowercased()
        if let raw = object["status"] as? [String: Any] { status = String(raw.keys.first ?? "unknown").lowercased() }
        if let code = object["exitCode"] ?? object["exit_code"], number(code) != 0 { status = "failed" }
        var duration = (object["durationMs"] as? NSNumber)?.doubleValue
        if let raw = object["duration"] as? [String: Any] {
            duration = Double(number(raw["secs"])) * 1000 + Double(number(raw["nanos"])) / 1_000_000
        }
        if duration == nil, let started, let ended { duration = max(0, ended.timeIntervalSince(started) * 1000) }
        let fingerprintData = Data((title + "\n" + ([TraceKind.user, .assistant].contains(kind) ? preview
            : json(object["arguments"] ?? object["command"]) + "\n" + output)).utf8)
        let fingerprint = SHA256.hash(data: fingerprintData).map { String(format: "%02x", $0) }.joined()
        let polling = ["wait", "sleep", "poll", "write_stdin", "get_handoff_status"].contains { title.lowercased().contains($0) }
        let readOnly = object["readOnlyHint"] as? Bool ?? false
        return TraceEvent(id: text(object["id"]).isEmpty ? "\(source.offset ?? 0):\(type)" : text(object["id"]),
            threadID: threadID, turnID: turnID, timestamp: ended ?? timestamp, startedAt: started,
            durationMs: duration, kind: kind, title: title, preview: summary(preview),
            status: status, source: source, outputBytes: output.utf8.count, fingerprint: fingerprint,
            readOnly: readOnly, isPolling: polling)
    }

    static func reduce(_ object: [String: Any], reference: SourceReference, state: inout RolloutState) -> UsageSample? {
        guard let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { return nil }
        let time = date(object["timestamp"]) ?? state.lastEventAt ?? Date(timeIntervalSince1970: 0)
        let eventKey = "\(reference.offset ?? 0)"
        state.lastEventAt = max(state.lastEventAt ?? time, time)
        var usageResult: UsageSample?
        switch type {
        case "turn_context":
            let model = text(payload["model"])
            if !model.isEmpty && state.model != model { state.segment = Int(reference.offset ?? 0); state.model = model }
            state.effort = text(payload["effort"])
            if let id = payload["turn_id"] as? String { state.turnID = id }
        case "session_meta":
            if let owner = payload["id"] as? String, owner != state.threadID {
                state.note = "日志归属与会话索引不一致，停止读取"
            }
        case "token_usage_record":
            guard text(payload["thread_id"]) == state.threadID, let tokens = tokens(payload["usage"]),
                  let responseID = payload["response_id"] as? String, !responseID.isEmpty else { break }
            state.modernUsage = true
            state.cumulative = self.tokens(payload["thread_token_usage"])
            state.turnUsage = self.tokens(payload["turn_token_usage"])
            let sample = UsageSample(id: responseID, threadID: state.threadID, turnID: text(payload["turn_id"]),
                                     timestamp: time, model: state.model, tokens: tokens)
            if !state.usage.contains(where: { $0.id == responseID }) { state.usage.append(sample); usageResult = sample }
        case "compacted":
            state.pendingCompaction = true
            state.segment = Int(reference.offset ?? 0)
        case "response_item":
            let responseType = text(payload["type"])
            let callID = text(payload["call_id"])
            if responseType == "message", !state.structuredItemsSeen,
               ["user", "assistant"].contains(text(payload["role"])) {
                var raw = payload
                raw["type"] = text(payload["role"]) == "user" ? "UserMessage" : "AgentMessage"
                raw["id"] = payload["id"] ?? "message:\(eventKey)"
                var event = item(raw, threadID: state.threadID, turnID: state.turnID, timestamp: time, source: reference)
                event.status = "raw"
                state.events.append(event)
            } else if ["function_call", "custom_tool_call"].contains(responseType), !callID.isEmpty {
                let name = text(payload["name"])
                let waiting = name.hasSuffix("request_user_input") || name.hasSuffix("request_user_input_async")
                let event = TraceEvent(id: callID, threadID: state.threadID, turnID: state.turnID,
                    timestamp: time, startedAt: time, kind: .tool, title: "调用请求 · \(name)",
                    preview: summary(text(payload["arguments"] ?? payload["input"])), status: "requested", source: reference)
                if !state.events.contains(where: { $0.id == callID }) { state.events.append(event) }
                // Asynchronous questions do not block execution.
                if waiting && !name.hasSuffix("_async") {
                    state.state = .waiting; state.stateAt = time
                }
            } else if ["function_call_output", "custom_tool_call_output"].contains(responseType),
                      let index = state.events.firstIndex(where: { $0.id == callID && $0.status == "requested" }) {
                state.events[index].status = "recorded"
                state.events[index].timestamp = time
                state.events[index].source = reference
                if state.state == .waiting && state.events[index].title.hasSuffix("request_user_input") {
                    state.state = .running; state.stateAt = time
                }
            }
        case "event_msg":
            let eventType = text(payload["type"])
            switch eventType {
            case "task_started":
                state.turnID = text(payload["turn_id"]); state.state = .running
                state.startedAt = date(payload["started_at"]) ?? time; state.stateAt = time; state.turnUsage = nil
                appendLifecycle("轮次开始", id: eventKey, time: time, reference: reference, state: &state)
            case "task_complete", "turn_aborted":
                state.state = eventType == "turn_aborted" ? .interrupted : (payload["error"] is [String: Any] ? .failed : .completed)
                state.stateAt = time
                appendLifecycle(state.state.label, id: eventKey, time: time, reference: reference, state: &state)
                if state.state == .failed {
                    state.events[state.events.count - 1].preview = summary(text(payload["error"]))
                    state.events[state.events.count - 1].status = "failed"
                }
            case "item_completed":
                if let raw = payload["item"] as? [String: Any] {
                    state.structuredItemsSeen = true
                    let event = item(raw, threadID: state.threadID, turnID: text(payload["turn_id"]),
                        timestamp: time, source: reference, started: date(payload["started_at_ms"]), ended: date(payload["completed_at_ms"]))
                    state.events.removeAll { $0.status == "raw" && $0.kind == event.kind && $0.fingerprint == event.fingerprint && $0.turnID == event.turnID }
                    if let index = state.events.firstIndex(where: { $0.id == event.id && $0.turnID == event.turnID }) { state.events[index] = event }
                    else { state.events.append(event) }
                    if event.kind == .compaction { state.pendingCompaction = true; state.segment = Int(reference.offset ?? 0) }
                }
            case "token_count":
                guard let info = payload["info"] as? [String: Any], let last = tokens(info["last_token_usage"]) else { break }
                let capacity = (info["model_context_window"] as? NSNumber)?.int64Value
                if let previous = state.contexts.last, previous.capacity != capacity { state.segment = Int(reference.offset ?? 0) }
                state.contexts.append(ContextSample(id: eventKey, timestamp: time, used: last.total, capacity: capacity,
                                                    model: state.model, segment: state.segment))
                state.pendingCompaction = false
                if !state.modernUsage, let cumulative = tokens(info["total_token_usage"]) {
                    if let old = state.cumulative {
                        let delta = TokenBreakdown(input: cumulative.input - old.input, cached: cumulative.cached - old.cached,
                            output: cumulative.output - old.output, reasoning: cumulative.reasoning - old.reasoning,
                            total: cumulative.total - old.total)
                        if min(delta.input, delta.cached, delta.output, delta.reasoning) >= 0 && delta.total > 0 {
                            let sample = UsageSample(id: "legacy:\(reference.path):\(eventKey)", threadID: state.threadID,
                                turnID: state.turnID, timestamp: time, model: state.model, tokens: delta, estimatedDelta: true)
                            state.usage.append(sample); usageResult = sample
                        }
                    }
                    state.cumulative = cumulative
                }
            case "error":
                appendLifecycle("错误记录", id: eventKey, time: time, reference: reference, state: &state)
                state.events[state.events.count - 1].preview = summary(text(payload["message"]))
                state.events[state.events.count - 1].status = "error"
            default: break
            }
        default: break
        }
        return usageResult
    }

    private static func appendLifecycle(_ title: String, id: String, time: Date, reference: SourceReference, state: inout RolloutState) {
        state.events.append(TraceEvent(id: "lifecycle:\(id)", threadID: state.threadID, turnID: state.turnID,
            timestamp: time, kind: .lifecycle, title: title, preview: "", status: "completed", source: reference))
    }
}

enum RolloutReader {
    static func consume(_ state: inout RolloutState, bootstrapBytes: Int = 512 * 1024,
                        byteBudget: Int = 2 * 1024 * 1024, initialOffset: UInt64? = nil,
                        endOffset: UInt64? = nil) throws -> [UsageSample] {
        let url = URL(fileURLWithPath: state.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: state.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let identity = "\((attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0):\((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)"
        let changed = state.initialized && (identity != state.identity || size < state.offset)
        if changed {
            let oldModel = state.model
            state = RolloutState(threadID: state.threadID, path: state.path)
            state.model = oldModel; state.note = "源文件已更换或截断，当前记录已重新定位"
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        if !state.initialized {
            // Validate ownership before using a cached index path.
            let header = try file.read(upToCount: 512 * 1024) ?? Data()
            if let end = header.firstIndex(of: 10),
               let object = try? JSONSerialization.jsonObject(with: header[..<end]) as? [String: Any],
               let payload = object["payload"] as? [String: Any],
               let owner = payload["id"] as? String, owner != state.threadID {
                throw StoreError.unavailable("日志归属与会话不一致")
            }
            var start = initialOffset ?? (size > UInt64(bootstrapBytes) ? size - UInt64(bootstrapBytes) : 0)
            if start > 0 {
                try file.seek(toOffset: start)
                let initial = try file.read(upToCount: bootstrapBytes) ?? Data()
                if let newline = initial.firstIndex(of: 10) { start += UInt64(newline + 1) }
                else { start = 0 }
            }
            state.offset = start; state.historyStartOffset = start
            state.historyComplete = start == 0
            state.initialized = true; state.identity = identity
        }
        try file.seek(toOffset: state.offset)
        let startOffset = state.offset
        let upper = min(endOffset ?? size, size)
        guard startOffset < upper else { return [] }
        var buffer = try file.read(upToCount: min(byteBudget, Int(upper - startOffset))) ?? Data()
        // A single large JSON line may exceed the normal scheduling budget.
        while !buffer.isEmpty && !buffer.contains(10) && buffer.count < 32 * 1024 * 1024 && startOffset + UInt64(buffer.count) < upper {
            buffer.append(try file.read(upToCount: min(byteBudget, Int(upper - startOffset) - buffer.count)) ?? Data())
        }
        if buffer.count >= 32 * 1024 * 1024 && !buffer.contains(10) {
            state.note = "单条记录超过 32 MiB，等待可解析的记录边界"
            return []
        }
        var usages: [UsageSample] = []
        var lineStart = 0
        for index in buffer.indices where buffer[index] == 10 {
            let line = buffer[lineStart..<index]
            let source = SourceReference(path: state.path, offset: startOffset + UInt64(lineStart), length: index - lineStart,
                                         threadID: state.threadID, recordDigest: ObservationParser.digest(Data(line)))
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                if let usage = ObservationParser.reduce(object, reference: source, state: &state) { usages.append(usage) }
            } else if !line.isEmpty { state.note = "部分记录无法解析，已保留其余可读数据" }
            state.offset = startOffset + UInt64(index + 1)
            lineStart = index + 1
        }
        state.events = Array(state.events.suffix(300))
        state.contexts = Array(state.contexts.suffix(2000))
        state.usage = Array(state.usage.suffix(2000))
        return usages
    }
}
