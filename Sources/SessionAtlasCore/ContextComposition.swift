import Foundation

public enum ContextCategory: String, Codable, Sendable, CaseIterable {
    case instructions, skills, environment, user, assistant, toolCall, toolResult, summary, attachment
    public var label: String {
        switch self {
        case .instructions: "规则与指令"
        case .skills: "可用技能说明"
        case .environment: "运行环境信息"
        case .user: "用户输入"
        case .assistant: "Agent 回复与进展"
        case .toolCall: "工具调用内容"
        case .toolResult: "工具返回"
        case .summary: "压缩摘要"
        case .attachment: "图片与附件"
        }
    }
    public var explanation: String {
        switch self {
        case .instructions: "日志中可见的行为要求、项目约定、权限边界与记忆使用说明。"
        case .skills: "可用 Skill 的介绍和调用条件，不表示这些技能都已加载或执行。"
        case .environment: "工作目录、时间、运行环境和可用插件等描述信息，不是环境健康检查。"
        case .user: "用户提出的问题、要求和补充说明。"
        case .assistant: "Agent 已生成的回答与执行进展，不包含工具调用参数。"
        case .toolCall: "Agent 交给工具的具体操作，例如终端命令、搜索词和文件修改内容。"
        case .toolResult: "工具返回的文件正文、检索结果、命令输出或报错；通过工具读取的 Skill 文档也在这里。"
        case .summary: "压缩后记录的摘要；加密保存的摘要只能确认存在，无法读取正文。"
        case .attachment: "本地记录中的图片或附件信息，不能据此精确计算其 Token 用量。"
        }
    }
}

public struct ContextMaterial: Identifiable, Sendable, Equatable {
    public var id: String
    public var category: ContextCategory
    public var title: String
    public var preview: String
    public var characters: Int
    public var timestamp: Date
    public var recordOffset: UInt64
    public var source: SourceReference
    public var fromReplacement: Bool
    public var readable: Bool
    public var event: TraceEvent {
        TraceEvent(id: id, threadID: source.threadID ?? "", turnID: "", timestamp: timestamp,
            kind: category == .summary ? .compaction : .unknown, title: title, preview: preview,
            status: "recorded", source: source)
    }
}

public struct ContextCheckpoint: Identifiable, Sendable, Equatable {
    public var id: UInt64
    public var timestamp: Date
    public var used: Int64
    public var capacity: Int64?
    public var model: String
    public var ratio: Double? { capacity.flatMap { $0 > 0 ? Double(used) / Double($0) : nil } }
}

public struct ContextPhase: Identifiable, Sendable, Equatable {
    public var id: UInt64
    public var number: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var materials: [ContextMaterial] = []
    public var checkpoints: [ContextCheckpoint] = []
    public var hasReplacement = false
    public var title: String { number == 0 ? "首次压缩前" : "第 \(number) 次压缩后" }

    public func materials(through checkpointID: UInt64?) -> [ContextMaterial] {
        materials.filter { checkpointID == nil || $0.recordOffset <= checkpointID! }
    }

    /// Adjacent samples in the same phase. A model/window change is not comparable.
    public func change(at checkpointID: UInt64) -> ContextChange? {
        guard let index = checkpoints.firstIndex(where: { $0.id == checkpointID }), index > 0 else { return nil }
        let previous = checkpoints[index - 1], current = checkpoints[index]
        let comparable = previous.model == current.model && previous.model != "未知模型"
            && previous.capacity == current.capacity && (current.capacity ?? 0) > 0
        return ContextChange(previous: previous, current: current,
            tokenDelta: comparable ? current.used - previous.used : nil,
            materials: materials.filter { $0.recordOffset > previous.id && $0.recordOffset <= current.id })
    }
}

public struct ContextChange: Sendable {
    public let previous: ContextCheckpoint
    public let current: ContextCheckpoint
    public let tokenDelta: Int64?
    public let materials: [ContextMaterial]
}

public struct ContextHistory: Sendable, Equatable {
    public var threadID = ""
    public var phases: [ContextPhase] = []
    public var readBytes: UInt64 = 0
    public var totalBytes: UInt64 = 0
    public var complete = false
    public var note: String?
    public init() {}
}

/// On-demand content index. It stores previews and source positions, never copied message bodies.
/// Replacement history resets the set of known materials; it is not an exact outbound prompt.
public actor ContextExplorer {
    private var history = ContextHistory()
    private var path = ""
    private var identity = ""
    private var model = "未知模型"
    private var calls: [String: String] = [:]
    private var materialCount = 0
    public init() {}

    public func load(threadID: String, path: String, byteBudget: Int = 8 * 1024 * 1024) -> ContextHistory {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let fileID = "\((attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0):\((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)"
            if history.threadID != threadID || self.path != path || identity != fileID || size < history.readBytes {
                history = ContextHistory(); history.threadID = threadID
                self.path = path; identity = fileID; model = "未知模型"; calls = [:]; materialCount = 0
            }
            history.totalBytes = size
            guard materialCount < 20_000 else {
                history.note = "已索引 20,000 项内容；此文件的后续内容尚未纳入组成视图。"
                history.complete = false
                return history
            }
            if size == history.readBytes { history.complete = true; return history }
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            try file.seek(toOffset: history.readBytes)
            let base = history.readBytes
            var data = try file.read(upToCount: min(max(byteBudget, 1024), Int(size - base))) ?? Data()
            while !data.isEmpty && !data.contains(10) && data.count < 32 * 1024 * 1024 && base + UInt64(data.count) < size {
                data.append(try file.read(upToCount: min(1024 * 1024, Int(size - base) - data.count)) ?? Data())
            }
            if data.count >= 32 * 1024 * 1024 && !data.contains(10) {
                history.note = "单条记录超过可解析范围，后续组成尚未读取。"
                history.complete = false; return history
            }
            var start = 0
            for end in data.indices where data[end] == 10 {
                let offset = base + UInt64(start)
                let line = Data(data[start..<end])
                if let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    let payload = record["payload"] as? [String: Any] ?? [:]
                    if offset == 0, record["type"] as? String == "session_meta",
                       let owner = payload["id"] as? String, owner != threadID {
                        history.note = "日志归属不匹配，无法建立上下文组成。"; return history
                    }
                    let reference = SourceReference(path: path, offset: offset, length: line.count,
                        threadID: threadID, recordDigest: ObservationParser.digest(line))
                    consume(record, reference: reference)
                } else if !line.isEmpty { history.note = "部分源记录无法解析，组成视图可能不完整。" }
                history.readBytes = base + UInt64(end + 1)
                start = end + 1
                if materialCount >= 20_000 { break }
            }
            history.complete = history.readBytes == size
        } catch { history.note = "上下文内容暂不可读，请重试。"; history.complete = false }
        return history
    }

    private func consume(_ record: [String: Any], reference: SourceReference) {
        let type = record["type"] as? String ?? ""
        let payload = record["payload"] as? [String: Any] ?? [:]
        let time = ObservationParser.date(record["timestamp"]) ?? history.phases.last?.startedAt ?? .distantPast
        if history.phases.isEmpty { history.phases.append(ContextPhase(id: 0, number: 0, startedAt: time)) }
        switch type {
        case "turn_context":
            model = payload["model"] as? String ?? model
        case "response_item":
            append(payload, reference: reference, pointer: ["payload"], time: time, replacement: false)
        case "compacted":
            history.phases[history.phases.count - 1].endedAt = time
            let replacement = payload["replacement_history"] as? [[String: Any]]
            history.phases.append(ContextPhase(id: reference.offset ?? 0, number: history.phases.count,
                startedAt: time, hasReplacement: replacement != nil))
            if let replacement {
                for (i, item) in replacement.enumerated() {
                    append(item, reference: reference, pointer: ["payload", "replacement_history", String(i)], time: time, replacement: true)
                }
            } else {
                let message = payload["message"] as? String ?? ""
                add(category: .summary, title: "压缩摘要", text: message,
                    reference: reference, pointer: ["payload", "message"], time: time, replacement: true,
                    opaque: message.isEmpty ? "运行时未提供可读摘要；本阶段只列出此后新增的内容。" : nil)
            }
        case "event_msg":
            if payload["type"] as? String == "token_count",
               let info = payload["info"] as? [String: Any],
               let usage = ObservationParser.tokens(info["last_token_usage"]) {
                history.phases[history.phases.count - 1].checkpoints.append(ContextCheckpoint(
                    id: reference.offset ?? 0, timestamp: time, used: usage.total,
                    capacity: (info["model_context_window"] as? NSNumber)?.int64Value, model: model))
            }
        default: break
        }
    }

    private func append(_ item: [String: Any], reference: SourceReference, pointer: [String],
                        time: Date, replacement: Bool) {
        let type = item["type"] as? String ?? ""
        let role = item["role"] as? String ?? ""
        switch type {
        case "message":
            if role == "assistant", item["phase"] as? String == "analysis" { return }
            if let content = item["content"] as? [[String: Any]] {
                for (i, part) in content.enumerated() {
                    let text = ObservationParser.text(part)
                    let partType = part["type"] as? String ?? ""
                    if partType.contains("image") || partType.contains("audio") {
                        add(category: .attachment, title: partType.contains("image") ? "图像内容" : "音频内容",
                            text: "", reference: reference, pointer: pointer + ["content", String(i)],
                            time: time, replacement: replacement, opaque: "非文本内容不计入字符组成；可在原任务中查看。")
                    } else if !text.isEmpty {
                        let (category, title) = classify(text, role: role)
                        add(category: category, title: title, text: text, reference: reference,
                            pointer: pointer + ["content", String(i)], time: time, replacement: replacement)
                    }
                }
            } else {
                let text = ObservationParser.text(item["content"])
                let (category, title) = classify(text, role: role)
                if !text.isEmpty { add(category: category, title: title, text: text, reference: reference,
                    pointer: pointer + ["content"], time: time, replacement: replacement) }
            }
        case "function_call", "custom_tool_call":
            let name = item["name"] as? String ?? "工具"
            if let callID = item["call_id"] as? String { calls[callID] = name }
            let key = item["arguments"] == nil ? "input" : "arguments"
            add(category: .toolCall, title: "调用 · \(shortTool(name))", text: ObservationParser.json(item[key]),
                reference: reference, pointer: pointer + [key], time: time, replacement: replacement)
        case "function_call_output", "custom_tool_call_output":
            let name = calls[item["call_id"] as? String ?? ""] ?? "工具"
            let output = ObservationParser.text(item["output"])
            add(category: .toolResult, title: "返回 · \(shortTool(name))",
                text: output.isEmpty ? ObservationParser.json(item["output"]) : output,
                reference: reference, pointer: pointer + ["output"], time: time, replacement: replacement)
        case "compaction":
            let text = ObservationParser.text(item["summary"] ?? item["text"])
            add(category: .summary, title: "压缩后保留的摘要", text: text,
                reference: reference, pointer: pointer, time: time, replacement: replacement,
                opaque: text.isEmpty ? "摘要由运行时加密保存，无法读取正文；不沿用压缩前的内容冒充当前记录。" : nil)
        case "reasoning":
            break // Private reasoning is not a visible context material.
        default: break
        }
    }

    private func add(category: ContextCategory, title: String, text: String, reference: SourceReference,
                     pointer: [String], time: Date, replacement: Bool, opaque: String? = nil) {
        guard materialCount < 20_000 else { return }
        var ref = reference; ref.jsonPointer = pointer
        history.phases[history.phases.count - 1].materials.append(ContextMaterial(
            id: "\(reference.offset ?? 0):\(pointer.joined(separator: "/"))", category: category,
            title: title, preview: opaque ?? ObservationParser.summary(text, limit: 280),
            characters: opaque == nil ? text.count : 0, timestamp: time, recordOffset: reference.offset ?? 0,
            source: ref, fromReplacement: replacement, readable: opaque == nil))
        materialCount += 1
    }

    private func classify(_ text: String, role: String) -> (ContextCategory, String) {
        let lead = String(text.prefix(2000))
        if lead.contains("<skills_instructions>") { return (.skills, "可用技能与调用约定") }
        if lead.contains("# AGENTS.md") || lead.contains("<user_instructions>") { return (.instructions, "项目约定 · AGENTS.md") }
        if lead.contains("<environment_context>") { return (.environment, "目录、时间与运行环境") }
        if lead.contains("<app-context>") { return (.instructions, "Codex 应用使用约定") }
        if lead.contains("<permissions instructions>") { return (.instructions, "权限与执行边界") }
        if lead.contains("<recommended_plugins>") { return (.environment, "可用插件清单") }
        if lead.contains("<collaboration_mode>") { return (.instructions, "协作模式") }
        if lead.contains("<multi_agent_role>") { return (.instructions, "Agent 分工与通信规则") }
        if lead.contains("<multi_agent_mode>") { return (.instructions, "Agent 使用限制") }
        if lead.hasPrefix("## Memory") { return (.instructions, "记忆检索与使用约定") }
        if lead.contains("<openviking-context>") { return (.instructions, "关联记忆") }
        if role == "developer" || role == "system" { return (.instructions, role == "system" ? "系统指令（日志可见部分）" : "运行规则与开发者指令") }
        if role == "assistant" { return (.assistant, "Agent 回复与进展") }
        let first = text.split(separator: "\n").first.map(String.init) ?? "用户输入"
        return (.user, ObservationParser.summary(first, limit: 65))
    }
    private func shortTool(_ name: String) -> String {
        if name.contains("exec_command") { return "终端命令" }
        if name.contains("apply_patch") { return "文件修改" }
        if name.contains("web") { return "网页检索" }
        if name == "exec" || name.hasSuffix(".exec") { return "工具执行" }
        if name == "js" || name.hasSuffix("__js") { return "应用界面操作" }
        return String(name.split(separator: ".").last ?? Substring(name))
    }
}
