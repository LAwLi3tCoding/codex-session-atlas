import Foundation

public enum SessionSortMode: String, CaseIterable, Sendable {
    case recentActivity, attentionFirst
    public var label: String { self == .recentActivity ? "最近活动" : "需关注优先" }
}

extension SessionSummary {
    /// Prefer execution evidence; use catalog recency only until evidence is available.
    public var activityAt: Date { [lastEventAt, turnStartedAt].compactMap { $0 }.max() ?? updatedAt }
}

/// One time value drives both ordering and the time shown in each sidebar row.
public struct SessionListOrder {
    private var activityByID: [String: Date]
    private var attentionIDs: Set<String>

    public init(_ sessions: [SessionSummary]) {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        activityByID = byID.mapValues(\.activityAt)
        attentionIDs = Set(sessions.filter { $0.attentionCount > 0 }.map(\.id))
        // Propagate descendant activity even when a group is collapsed. Guard malformed cycles.
        for session in sessions {
            var parent = session.parentID
            var visited: Set<String> = [session.id]
            while let id = parent, let ancestor = byID[id], visited.insert(id).inserted {
                activityByID[id] = max(activityByID[id] ?? .distantPast, session.activityAt)
                if session.attentionCount > 0 { attentionIDs.insert(id) }
                parent = ancestor.parentID
            }
        }
    }

    public func activity(for session: SessionSummary) -> Date { activityByID[session.id] ?? session.activityAt }

    public func sorted(_ sessions: [SessionSummary], mode: SessionSortMode = .recentActivity) -> [SessionSummary] {
        sessions.sorted { a, b in
            if mode == .attentionFirst, attentionIDs.contains(a.id) != attentionIDs.contains(b.id) {
                return attentionIDs.contains(a.id)
            }
            let aTime = activity(for: a), bTime = activity(for: b)
            if aTime != bTime { return aTime > bTime }
            return a.id < b.id
        }
    }
}
