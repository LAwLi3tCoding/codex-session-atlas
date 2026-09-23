import Foundation

public enum ExecutionState: String, Codable, Sendable, CaseIterable {
    case unknown, running, waiting, completed, failed, interrupted, unconfirmed
    public var label: String {
        switch self {
        case .unknown: "未知"
        case .unconfirmed: "状态待确认"
        case .running: "最近活跃"
        case .waiting: "等待用户"
        case .completed: "本轮结束"
        case .failed: "失败"
        case .interrupted: "已中断"
        }
    }
}

public struct SessionSummary: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var workspace: String
    public var source: String
    public var model: String
    public var effort: String
    public var nickname: String?
    public var parentID: String?
    public var rolloutPath: String?
    public var archived: Bool
    public var updatedAt: Date
    public var state: ExecutionState = .unknown
    public var turnID: String?
    public var turnStartedAt: Date?
    public var lastEventAt: Date?
    public var latestAction: String?
    public var context: ContextSample?
    public var cumulativeUsage: TokenBreakdown?
    public var attentionCount = 0
    public var dataNote: String?
    public var activityNote: String?
    public var isRecentlyActive: Bool { state == .running && !archived }
    public static let activityWindow: TimeInterval = 5 * 60

    /// A persisted inProgress flag is not a heartbeat. Catalog edits are not execution evidence.
    mutating func checkActivity(at now: Date) {
        guard state == .running else {
            if state != .unconfirmed { activityNote = nil }
            return
        }
        let evidence = [lastEventAt, turnStartedAt].compactMap { $0 }.max()
        if let evidence, (-60...Self.activityWindow).contains(now.timeIntervalSince(evidence)) {
            activityNote = nil
        } else {
            state = .unconfirmed
            activityNote = "最近 5 分钟没有可确认的执行记录。日志最后标记为运行中，当前是否仍运行需到原任务确认。"
        }
    }
    public var isSystem: Bool { model == "codex-auto-review" || source.lowercased().contains("review") || source.lowercased().contains("compact") }
    public var workspaceName: String { URL(fileURLWithPath: workspace).lastPathComponent }
}

public enum TraceKind: String, Codable, CaseIterable, Sendable {
    case user, assistant, tool, file, agent, compaction, lifecycle, plan, reasoning, unknown
    public var label: String {
        switch self {
        case .user: "输入"
        case .assistant: "回复"
        case .tool: "工具"
        case .file: "修改"
        case .agent: "Agent"
        case .compaction: "压缩"
        case .lifecycle: "轮次"
        case .plan: "计划"
        case .reasoning: "可见推理摘要"
        case .unknown: "其他"
        }
    }
}

public struct SourceReference: Codable, Sendable, Equatable {
    public var path: String
    public var offset: UInt64?
    public var length: Int?
    public var threadID: String?
    public var turnID: String?
    public var itemID: String?
    public var recordDigest: String?
    public var jsonPointer: [String]?
}

public struct TraceEvent: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var threadID: String
    public var turnID: String
    public var timestamp: Date
    public var startedAt: Date?
    public var durationMs: Double?
    public var kind: TraceKind
    public var title: String
    public var preview: String
    public var status: String
    public var source: SourceReference
    public var outputBytes: Int = 0
    public var fingerprint: String?
    public var readOnly = false
    public var isPolling = false
    // Source text must stay verbatim even when it matches an app label.
    public var titleIsSource = false
    public var previewIsAppText = false
    public var failed: Bool { status == "failed" || status == "error" || status == "declined" }
}

public struct TokenBreakdown: Codable, Sendable, Equatable {
    public var input: Int64 = 0
    public var cached: Int64 = 0
    public var output: Int64 = 0
    public var reasoning: Int64 = 0
    public var total: Int64 = 0
    public init(input: Int64 = 0, cached: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0, total: Int64 = 0) {
        self.input = input; self.cached = cached; self.output = output; self.reasoning = reasoning; self.total = total
    }
    public var cacheRatio: Double? { input > 0 ? Double(cached) / Double(input) : nil }
}

public struct UsageSample: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var threadID: String
    public var turnID: String
    public var timestamp: Date
    public var model: String
    public var tokens: TokenBreakdown
    public var estimatedDelta: Bool = false
}

public struct ContextSample: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var timestamp: Date
    public var used: Int64
    public var capacity: Int64?
    public var model: String
    public var segment: Int
    public var ratio: Double? {
        guard let capacity, capacity > 0 else { return nil }
        return Double(used) / Double(capacity)
    }
}

public struct AttentionItem: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var threadID: String
    public var rule: String
    public var title: String
    public var explanation: String
    public var advice: String
    public var timestamp: Date
    public var evidenceID: String?
    public var evidence: SourceReference?
    public var definite: Bool
    public var resolved = false
    public var seen = false
    public var explanationIsSource = false
}

public struct RuleSettings: Codable, Sendable, Equatable {
    public var repeatCount = 3
    public var repeatMinutes = 5
    public var contextHigh = 0.85
    public var contextClear = 0.75
    public var largeOutputBytes = 128 * 1024
    public var silenceMinutes = 10
    public init() {}
}

public struct RolloutState: Codable, Sendable {
    public var threadID: String
    public var path: String
    public var identity: String = ""
    public var offset: UInt64 = 0
    public var historyStartOffset: UInt64 = 0
    public var model = ""
    public var effort = ""
    public var turnID = ""
    public var state: ExecutionState = .unknown
    public var startedAt: Date?
    public var lastEventAt: Date?
    public var stateAt: Date?
    public var events: [TraceEvent] = []
    public var contexts: [ContextSample] = []
    public var usage: [UsageSample] = []
    public var cumulative: TokenBreakdown?
    public var turnUsage: TokenBreakdown?
    public var modernUsage = false
    public var structuredItemsSeen = false
    public var segment = 0
    public var pendingCompaction = false
    public var alerts: [AttentionItem] = []
    public var note: String?
    public var historyComplete = true
    public var initialized = false
    public init(threadID: String, path: String) { self.threadID = threadID; self.path = path }
}

public struct TimelinePage: Sendable {
    public var events: [TraceEvent]
    public var before: Int64?
    public var hasMore: Bool
    public var note: String?
}

public struct ObservationSnapshot: Sendable {
    public var sessions: [SessionSummary] = []
    public var attention: [AttentionItem] = []
    public var diagnostics: [String] = []
    public var observedTokens: Int64 = 0
    public var monitoredSince = Date()
    public var refreshedAt: Date?
    public var initializedCount = 0
    public var durationMs: Double = 0
    public init() {}
}

public struct SessionObservation: Sendable {
    public var contexts: [ContextSample] = []
    public var usage: [UsageSample] = []
    public var events: [TraceEvent] = []
    public var attention: [AttentionItem] = []
    public var cumulative: TokenBreakdown?
    public var turnUsage: TokenBreakdown?
    public var pendingCompaction = false
    public var historyComplete = false
    public var note: String?
    public init() {}
}

public struct RecordDetail: Sendable {
    public var text: String
    public var hasMore: Bool
    public init(text: String, hasMore: Bool = false) { self.text = text; self.hasMore = hasMore }
}

extension TraceEvent {
    public func localizedTitle(language: AppLanguage = .current) -> String {
        titleIsSource ? title : L(title, language: language)
    }
    public func localizedPreview(language: AppLanguage = .current) -> String {
        previewIsAppText ? L(preview, language: language) : preview
    }
}
extension AttentionItem {
    public func localizedExplanation(language: AppLanguage = .current) -> String {
        explanationIsSource ? explanation : L(explanation, language: language)
    }
}
