import CoreServices
import Foundation

private final class ChangeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()
    func insert(_ values: [String]) { lock.lock(); paths.formUnion(values); lock.unlock() }
    func drain() -> Set<String> { lock.lock(); defer { lock.unlock() }; let result = paths; paths.removeAll(); return result }
}

private final class RolloutWatcher {
    private var stream: FSEventStreamRef?
    init(home: URL, signal: ChangeSignal) {
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(signal).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<ChangeSignal>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<ChangeSignal>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, context, count, rawPaths, _, _ in
            guard let context else { return }
            let signal = Unmanaged<ChangeSignal>.fromOpaque(context).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            signal.insert(Array(paths.prefix(count)))
        }
        stream = FSEventStreamCreate(nil, callback, &context, [home.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "monitor.files"))
            FSEventStreamStart(stream)
        }
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}

private struct FileStamp: Equatable {
    let size: UInt64
    let inode: UInt64
    let modified: Date?
    init?(_ path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date
    }
}

public actor MonitorEngine {
    private let source: ObservationSource
    private let cacheDirectory: URL
    private var cache: ObservationCache?
    private var states: [String: RolloutState] = [:]
    private var sessions: [SessionSummary] = []
    private var snapshot = ObservationSnapshot()
    private let signal = ChangeSignal()
    private var watcher: RolloutWatcher?
    private var settings = RuleSettings()
    private var refreshNumber = 0
    private var stopped = false
    private var stamps: [String: FileStamp] = [:]
    private var pendingIDs: [String] = []
    private var latestTurns: [String: [String: String]] = [:]
    private var seen = Set<String>()
    private var initializedIDs = Set<String>()
    private var attentionByThread: [String: [AttentionItem]] = [:]
    private var lastRead: [String: Date] = [:]
    private var logPaging = Set<String>()

    public init(home: URL, cacheDirectory: URL) {
        source = ObservationSource(home: home)
        self.cacheDirectory = cacheDirectory
    }
    public func start() { stopped = false; if watcher == nil { watcher = RolloutWatcher(home: source.home, signal: signal) } }
    public func stop() { stopped = true; watcher = nil }
    public func updateSettings(_ value: RuleSettings) { settings = value }
    public func markSeen(_ id: String) { seen.insert(id); try? cache?.markSeen(id) }

    public func poll(selectedID: String? = nil, now: Date = Date()) -> ObservationSnapshot {
        guard !stopped else { return snapshot }
        let started = Date()
        let previous = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var diagnostics: [String] = []
        if cache == nil {
            do {
                let opened = try ObservationCache(directory: cacheDirectory)
                seen = try opened.seenIDs()
                pendingIDs += try opened.checkpointIDs()
                cache = opened
            }
            catch { diagnostics.append("本地缓存不可写：本次仅内存采集，重启后需重新初始化") }
        }
        do { sessions = try source.catalog() }
        catch {
            for index in snapshot.sessions.indices { snapshot.sessions[index].checkActivity(at: now) }
            snapshot.diagnostics = ["会话索引读取失败，显示上次快照：\(error)"]
            snapshot.durationMs = Date().timeIntervalSince(started) * 1000
            return snapshot
        }
        do { latestTurns = try source.latestTurns() }
        catch { diagnostics.append("分页历史读取失败，保留上次状态并继续采集日志：\(error)") }
        let turns = latestTurns
        let changed = signal.drain()
        let reconcile = refreshNumber % 15 == 0
        refreshNumber += 1
        var pending: [SessionSummary] = []
        var queued = Set<String>()
        func enqueue(_ session: SessionSummary) {
            if queued.insert(session.id).inserted { pending.append(session) }
        }
        if let selectedID, let session = sessions.first(where: { $0.id == selectedID }) { enqueue(session) }
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for id in pendingIDs { if let session = byID[id] { enqueue(session) } }
        pendingIDs.removeAll(keepingCapacity: true)
        for session in sessions {
            let turn = turns[session.id]
            let recent = now.timeIntervalSince(session.updatedAt) < 86400
            if recent && (!initializedIDs.contains(session.id) || previous[session.id]?.updatedAt != session.updatedAt) { enqueue(session) }
            if turn?["status"] == "inProgress" && reconcile && !initializedIDs.contains(session.id) { enqueue(session) }
            if let path = session.rolloutPath, changed.contains(path) { enqueue(session) }
            if let path = session.rolloutPath, !path.isEmpty {
                let state = states[session.id]
                if state != nil || reconcile {
                    let stamp = FileStamp(path)
                    if let oldStamp = stamps[session.id] {
                        if stamp != oldStamp || (state?.offset ?? stamp?.size ?? 0) < (stamp?.size ?? 0) { enqueue(session) }
                    } else if state != nil { enqueue(session) }
                    else { stamps[session.id] = stamp }
                }
            }
        }
        var deferred = 0
        for session in pending {
            if Date().timeIntervalSince(started) > 1.4 { deferred += 1; pendingIDs.append(session.id); continue }
            guard let path = session.rolloutPath, !path.isEmpty else { continue }
            do {
                var state = try states[session.id] ?? cache?.load(session.id) ?? RolloutState(threadID: session.id, path: path)
                let oldOffset = state.offset
                if state.path != path { state.path = path }
                if state.model.isEmpty { state.model = session.model }
                if state.effort.isEmpty { state.effort = session.effort }
                let usage = try RolloutReader.consume(&state)
                if state.note == "源记录读取失败，保留上次观测" || state.note == "源记录暂不可读，仍保留会话目录" { state.note = nil }
                state.alerts = AttentionRules.evaluate(state, settings: settings, now: now)
                if state.offset != oldOffset || states[session.id] == nil {
                    // Cache and cursor commit together; a failed transaction is retried on the next poll.
                    if let cache { try cache.save(state, newUsage: usage) }
                }
                states[session.id] = state
                initializedIDs.insert(session.id)
                lastRead[session.id] = now
                stamps[session.id] = FileStamp(path)
                if state.offset < (stamps[session.id]?.size ?? 0) { pendingIDs.append(session.id) }
            } catch {
                pendingIDs.append(session.id)
                if var old = states[session.id] { old.note = "源记录读取失败，保留上次观测"; states[session.id] = old }
                else {
                    var state = RolloutState(threadID: session.id, path: path)
                    state.note = "源记录暂不可读，仍保留会话目录"
                    states[session.id] = state
                }
            }
        }
        var allAttention: [AttentionItem] = []
        for index in sessions.indices {
            let id = sessions[index].id
            if let old = previous[id] {
                sessions[index].state = old.state
                sessions[index].turnID = old.turnID
                sessions[index].turnStartedAt = old.turnStartedAt
                sessions[index].activityNote = old.activityNote
            }
            if let turn = turns[id] {
                sessions[index].turnID = turn["turn_id"]
                sessions[index].turnStartedAt = turn["started_at"].flatMap(Double.init).flatMap { ObservationParser.date(NSNumber(value: $0)) }
                switch turn["status"] {
                case "inProgress": sessions[index].state = .running
                case "completed": sessions[index].state = .completed
                case "failed": sessions[index].state = .failed
                case "interrupted": sessions[index].state = .interrupted
                default: break
                }
            }
            guard var state = states[id] else {
                sessions[index].context = previous[id]?.context
                sessions[index].cumulativeUsage = previous[id]?.cumulativeUsage
                sessions[index].lastEventAt = previous[id]?.lastEventAt
                sessions[index].latestAction = previous[id]?.latestAction
                sessions[index].dataNote = sessionHasLog(sessions[index])
                    ? previous[id]?.dataNote ?? "上下文按需加载，新增活动仍持续监听"
                    : "无可读的本地轨迹：仅显示目录，尚未接入实时监控"
                continue
            }
            let sameTurn = sessions[index].turnID == nil || sessions[index].turnID == state.turnID
            let persistedTime = ["started_at", "completed_at"].compactMap { key in
                turns[id]?[key].flatMap(Double.init).flatMap { ObservationParser.date(NSNumber(value: $0)) }
            }.max() ?? .distantPast
            if state.state != .unknown && (state.stateAt ?? .distantPast) >= persistedTime {
                sessions[index].state = state.state
                sessions[index].turnID = state.turnID
                sessions[index].turnStartedAt = state.startedAt
            }
            // A newer persisted completion also resolves alerts from an older log tail.
            state.state = sessions[index].state
            state.turnID = sessions[index].turnID ?? state.turnID
            state.startedAt = sessions[index].turnStartedAt ?? state.startedAt
            if persistedTime > (state.stateAt ?? .distantPast) { state.stateAt = persistedTime }
            state.alerts = AttentionRules.evaluate(state, settings: settings, now: now)
            states[id] = state
            sessions[index].lastEventAt = state.lastEventAt
            if sameTurn { sessions[index].turnStartedAt = state.startedAt ?? sessions[index].turnStartedAt }
            sessions[index].latestAction = state.events.last?.title
            sessions[index].context = state.contexts.last
            sessions[index].cumulativeUsage = state.cumulative
            sessions[index].dataNote = state.note ?? (state.initialized ? nil : "初始化中")
            var alerts = state.alerts
            for i in alerts.indices { alerts[i].seen = seen.contains(alerts[i].id) }
            sessions[index].attentionCount = alerts.filter { !$0.resolved && !$0.seen }.count
            attentionByThread[id] = alerts
        }
        for index in sessions.indices {
            let id = sessions[index].id
            // Classify display freshness after merging sources; keep raw rollout state intact.
            sessions[index].checkActivity(at: now)
            let alerts = (attentionByThread[id] ?? []).map { item in var item = item; item.seen = seen.contains(item.id); return item }
            sessions[index].attentionCount = alerts.filter { !$0.resolved && !$0.seen }.count
            allAttention += alerts
        }
        // Persisted checkpoints permit evicting detailed data while keeping every session discoverable.
        if cache != nil && states.count > 128 {
            let candidates = states.keys.filter { $0 != selectedID }.sorted { (lastRead[$0] ?? .distantPast) < (lastRead[$1] ?? .distantPast) }
            for id in candidates.prefix(states.count - 128) { states.removeValue(forKey: id) }
        }
        if deferred > 0 { diagnostics.append("\(deferred) 个会话等待下一批增量处理") }
        snapshot.sessions = sessions
        snapshot.attention = allAttention.sorted { $0.timestamp > $1.timestamp }
        snapshot.diagnostics = diagnostics
        snapshot.initializedCount = initializedIDs.count
        snapshot.refreshedAt = now
        snapshot.durationMs = Date().timeIntervalSince(started) * 1000
        if let cache {
            snapshot.monitoredSince = max(cache.since, now.addingTimeInterval(-30 * 86400))
            snapshot.observedTokens = (try? cache.observedTotal()) ?? snapshot.observedTokens
        }
        return snapshot
    }

    public func observation(_ threadID: String) -> SessionObservation {
        guard let state = states[threadID] else { return SessionObservation() }
        var result = SessionObservation()
        result.contexts = state.contexts; result.usage = state.usage; result.events = state.events
        result.attention = state.alerts.map { item in var item = item; item.seen = seen.contains(item.id); return item }
        result.cumulative = state.cumulative; result.turnUsage = state.turnUsage
        result.pendingCompaction = state.pendingCompaction; result.historyComplete = state.historyComplete; result.note = state.note
        return result
    }
    public func loadEarlierContext(_ threadID: String) -> SessionObservation {
        guard var state = states[threadID], state.historyStartOffset > 0 else { return observation(threadID) }
        let upper = state.historyStartOffset
        var older = RolloutState(threadID: threadID, path: state.path)
        older.model = state.model
        do {
            _ = try RolloutReader.consume(&older, byteBudget: 2 * 1024 * 1024,
                initialOffset: upper > 512 * 1024 ? upper - 512 * 1024 : 0, endOffset: upper)
            state.historyStartOffset = older.historyStartOffset
            state.historyComplete = older.historyComplete
            let contextIDs = Set(state.contexts.map(\.id))
            state.contexts = Array((older.contexts.filter { !contextIDs.contains($0.id) } + state.contexts).suffix(2000))
            let usageIDs = Set(state.usage.map(\.id))
            state.usage = Array((older.usage.filter { !usageIDs.contains($0.id) } + state.usage).suffix(2000))
            // This is history viewing, not new observed consumption.
            states[threadID] = state
        } catch { state.note = "更早的上下文记录暂不可读"; states[threadID] = state }
        return observation(threadID)
    }
    public func timeline(_ threadID: String, before: Int64? = nil) -> TimelinePage {
        if logPaging.contains(threadID) { return logTimeline(threadID, before: before) }
        do {
            var page = try source.timeline(threadID: threadID, before: before)
            if page.events.isEmpty && before == nil {
                logPaging.insert(threadID)
                return logTimeline(threadID, before: nil)
            }
            if before == nil, let state = states[threadID] {
                let ids = Set(page.events.map(\.id))
                let oldest = page.events.last?.timestamp ?? .distantPast
                page.events += state.events.filter { !ids.contains($0.id) && $0.timestamp >= oldest }
                page.events.sort { $0.timestamp > $1.timestamp }
                if page.events.isEmpty { page.events = state.events.reversed() }
            }
            return page
        } catch {
            return TimelinePage(events: Array(states[threadID]?.events.reversed() ?? []), before: nil,
                                hasMore: false, note: "分页历史不可读，显示已采集事件")
        }
    }
    private func logTimeline(_ id: String, before: Int64?) -> TimelinePage {
        guard let state = states[id] else { return TimelinePage(events: [], hasMore: false, note: "日志尚未初始化") }
        if let before, before > 0 {
            var older = RolloutState(threadID: id, path: state.path)
            older.model = state.model
            do {
                let upper = UInt64(before)
                _ = try RolloutReader.consume(&older, initialOffset: upper > 512 * 1024 ? upper - 512 * 1024 : 0, endOffset: upper)
                let next = older.events.first?.source.offset ?? older.historyStartOffset
                return TimelinePage(events: older.events.reversed(), before: Int64(next), hasMore: next > 0 && next < upper,
                                    note: "兼容模式：按日志区段读取轨迹")
            } catch { return TimelinePage(events: [], hasMore: false, note: "较早日志暂不可读") }
        }
        let next = state.events.first?.source.offset ?? state.historyStartOffset
        return TimelinePage(events: state.events.reversed(), before: Int64(next), hasMore: next > 0,
                            note: "轨迹来自持久化日志；未持久化的中间状态不可见")
    }
    private func sessionHasLog(_ session: SessionSummary) -> Bool {
        session.rolloutPath?.isEmpty == false
    }
    public func detail(_ reference: SourceReference, offset: Int = 0, readable: Bool = false) -> String {
        do { return try ObservationSource.detail(reference, characterOffset: offset, readable: readable).text }
        catch { return "无法读取源记录：\(error)" }
    }
    public func detailPage(_ reference: SourceReference, offset: Int = 0, readable: Bool = false,
                           language: AppLanguage = .current) -> RecordDetail {
        do { return try ObservationSource.detail(reference, characterOffset: offset, readable: readable, language: language) }
        catch { return RecordDetail(text: Localization.diagnostic("无法读取源记录：\(error)", language: language)) }
    }

}
