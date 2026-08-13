import Foundation
import SQLite3

public enum MonitorPanelMode: Equatable {
    case compact
    case overview
    case inspector
}

public enum MonitorPanelLayout {
    public static func mode(forWidth width: Double) -> MonitorPanelMode {
        if width >= 1_280 { return .inspector }
        if width >= 900 { return .overview }
        return .compact
    }

    public static func resolvedSelection(preferredID: String?, availableIDs: [String]) -> String? {
        if let preferredID, availableIDs.contains(preferredID) { return preferredID }
        return availableIDs.first
    }
}

public enum CodexRuntimeTitle {
    public static func resolve(threadID: String, name: String?, preview: String?) -> String {
        for candidate in [name, preview] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
        }
        return threadID
    }
}

public struct AppServerRequestState {
    public private(set) var requestID: Int?
    private var nextRequestID = 1

    public init() {}

    public mutating func startNext() -> Int? {
        guard requestID == nil else { return nil }
        let requestID = nextRequestID
        nextRequestID += 1
        self.requestID = requestID
        return requestID
    }

    public mutating func finish(_ requestID: Int) -> Bool {
        guard self.requestID == requestID else { return false }
        self.requestID = nil
        return true
    }

    public mutating func expire(_ requestID: Int) -> Bool {
        finish(requestID)
    }

    public mutating func reset() {
        requestID = nil
    }
}

public struct AgentNode: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let activity: String?
    public let workspaceName: String
    let workspaceKey: String
    public let model: String
    public let reasoningEffort: String
    public let role: String?
    public let tokensUsed: Int?
    public let updatedAt: Date?
    public let isActive: Bool
    public let lifecycle: String?
    public let children: [AgentNode]

    public var currentActivity: String? { isActive ? activity : nil }
}

public struct WorkspaceGroup: Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let sessions: [AgentNode]
}

public struct AgentSnapshot: Equatable {
    public let roots: [AgentNode]
    public let diagnostics: [String]

    public var workspaces: [WorkspaceGroup] {
        var keys: [String] = []
        var grouped: [String: [AgentNode]] = [:]
        for root in roots {
            if grouped[root.workspaceKey] == nil { keys.append(root.workspaceKey) }
            grouped[root.workspaceKey, default: []].append(root)
        }
        return keys.map { key in
            let sessions = grouped[key] ?? []
            return WorkspaceGroup(id: key.hashValue, name: sessions.first?.workspaceName ?? "Unknown workspace", sessions: sessions)
        }
    }

    public init(roots: [AgentNode], diagnostics: [String]) {
        self.roots = roots
        self.diagnostics = diagnostics
    }
}

public struct SQLiteAgentStore {
    public init() {}

    public func load(at databaseURL: URL, runtimeTitles: [String: String] = [:]) -> AgentSnapshot {
        guard let database = ReadOnlyDatabase(path: databaseURL.path) else {
            return AgentSnapshot(roots: [], diagnostics: ["SQLite data is unavailable."])
        }
        guard database.hasTable("threads") else {
            return AgentSnapshot(roots: [], diagnostics: ["No Codex thread data was found."])
        }

        let columns = database.columns(in: "threads")
        guard columns.contains("id") else {
            return AgentSnapshot(roots: [], diagnostics: ["Codex thread data is missing its identifier."])
        }
        guard columns.contains("recency_at_ms") else {
            return AgentSnapshot(roots: [], diagnostics: ["Codex activity metadata is unavailable."])
        }

        let rows = database.threadRows(columns: columns)
        let edges = database.edgesIfAvailable()
        let roots = AgentTree.build(rows: rows, edges: edges, runtimeTitles: runtimeTitles)
        return AgentSnapshot(
            roots: roots,
            diagnostics: roots.isEmpty ? ["No sessions were active in the last 15 minutes."] : []
        )
    }
}

private struct ThreadRow {
    let id: String
    let name: String?
    let nickname: String?
    let workspaceKey: String
    let workspaceName: String
    let treeWorkspaceKey: String
    let agentPath: String?
    let model: String
    let reasoningEffort: String
    let role: String?
    let tokensUsed: Int?
    let updatedAt: Date?
    let isActive: Bool
}

private struct SpawnEdge {
    let parentID: String
    let childID: String
    let status: String?
}

private enum AgentTree {
    static func build(rows: [ThreadRow], edges: [SpawnEdge], runtimeTitles: [String: String]) -> [AgentNode] {
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var resolvedEdges = edges.filter { rowsByID[$0.parentID] != nil && rowsByID[$0.childID] != nil }
        let linkedChildIDs = Set(resolvedEdges.map(\.childID))
        let rowsByWorkspace = Dictionary(grouping: rows, by: \.treeWorkspaceKey)

        for row in rows where !linkedChildIDs.contains(row.id) {
            guard let agentPath = row.agentPath, agentPath.hasPrefix("/root/") else { continue }
            let parentPath = (agentPath as NSString).deletingLastPathComponent
            let candidates = (rowsByWorkspace[row.treeWorkspaceKey] ?? []).filter { candidate in
                candidate.id != row.id && (candidate.agentPath == parentPath || (parentPath == "/root" && candidate.agentPath == nil))
            }
            if candidates.count == 1 {
                resolvedEdges.append(SpawnEdge(parentID: candidates[0].id, childID: row.id, status: nil))
            }
        }

        let lifecycleByChild = Dictionary(uniqueKeysWithValues: resolvedEdges.map { ($0.childID, $0.status) })
        let childrenByParent = Dictionary(grouping: resolvedEdges, by: \.parentID)
        let childIDs = Set(childrenByParent.values.flatMap { $0.map(\.childID) })
        let rootIDs = rows.map(\.id).filter { !childIDs.contains($0) }

        func node(_ id: String, ancestors: Set<String>) -> AgentNode? {
            guard !ancestors.contains(id), let row = rowsByID[id] else { return nil }
            let nextAncestors = ancestors.union([id])
            let children = (childrenByParent[id] ?? []).compactMap { node($0.childID, ancestors: nextAncestors) }
            guard row.isActive || !children.isEmpty else { return nil }
            let isSubagent = childIDs.contains(id)
            let displayTitle = runtimeTitles[id] ?? row.name
            return AgentNode(
                id: row.id,
                name: isSubagent ? row.nickname ?? "Sub-agent" : displayTitle ?? row.id,
                activity: activity(for: row, displayTitle: displayTitle, isSubagent: isSubagent),
                workspaceName: row.workspaceName,
                workspaceKey: row.workspaceKey,
                model: row.model,
                reasoningEffort: row.reasoningEffort,
                role: row.role,
                tokensUsed: row.tokensUsed,
                updatedAt: row.updatedAt,
                isActive: row.isActive,
                lifecycle: lifecycleByChild[id] ?? nil,
                children: children
            )
        }

        return rootIDs.compactMap { node($0, ancestors: []) }
    }

    private static func activity(for row: ThreadRow, displayTitle: String?, isSubagent: Bool) -> String? {
        if let displayTitle { return displayTitle }
        guard isSubagent, let agentPath = row.agentPath else { return nil }

        var task = (agentPath as NSString).lastPathComponent
        let modelPrefix = normalizedIdentifier(row.model)
        if !modelPrefix.isEmpty, task.hasPrefix("\(modelPrefix)_") {
            task.removeFirst(modelPrefix.count + 1)
        }

        let phrase = task.split(separator: "_").joined(separator: " ")
        guard let first = phrase.first else { return nil }
        return first.uppercased() + phrase.dropFirst()
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
            .split(separator: "_")
            .joined(separator: "_")
    }
}

private final class ReadOnlyDatabase {
    private var handle: OpaquePointer?

    init?(path: String) {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 250)
    }

    deinit { sqlite3_close(handle) }

    func hasTable(_ table: String) -> Bool {
        scalar("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1", bind: table) != nil
    }

    func columns(in table: String) -> Set<String> {
        strings("PRAGMA table_info(\(table))", column: 1).reduce(into: Set<String>()) { $0.insert($1) }
    }

    func threadRows(columns: Set<String>) -> [ThreadRow] {
        let name = displayNameExpression(columns)
        let nickname = columns.contains("agent_nickname") ? "NULLIF(agent_nickname, '')" : "NULL"
        let workspace = optionalColumn("cwd", columns: columns)
        let agentPath = optionalColumn("agent_path", columns: columns)
        let model = optionalColumn("model", columns: columns)
        let effort = optionalColumn("reasoning_effort", columns: columns)
        let role = optionalColumn("agent_role", columns: columns)
        let tokens = optionalColumn("tokens_used", columns: columns)
        let activityTimestamp = columns.contains("updated_at_ms")
            ? "MAX(recency_at_ms, COALESCE(updated_at_ms, 0))"
            : "recency_at_ms"
        let active = "\(activityTimestamp) >= \(Int64(Date().addingTimeInterval(-15 * 60).timeIntervalSince1970 * 1_000))"
        var filters: [String] = []
        if columns.contains("archived") { filters.append("COALESCE(archived, 0) = 0") }
        if columns.contains("model") { filters.append("COALESCE(model, '') <> 'codex-auto-review'") }
        let whereClause = filters.isEmpty ? "" : "WHERE \(filters.joined(separator: " AND "))"
        let orderBy = columns.contains("updated_at_ms") ? "ORDER BY updated_at_ms DESC" : ""
        let sql = "SELECT id, \(name), \(nickname), \(model), \(effort), \(role), \(tokens), \(activityTimestamp), \(active), \(workspace), \(agentPath) FROM threads \(whereClause) \(orderBy)"

        return query(sql) { statement in
            let id = text(statement, 0) ?? ""
            let workspacePath = text(statement, 9) ?? "__unknown_workspace__"
            let workspaceLabel = workspaceName(workspacePath)
            return ThreadRow(
                id: id,
                name: text(statement, 1),
                nickname: text(statement, 2),
                workspaceKey: workspaceLabel,
                workspaceName: workspaceLabel,
                treeWorkspaceKey: normalizedWorkspacePath(workspacePath),
                agentPath: text(statement, 10),
                model: text(statement, 3) ?? "Unavailable",
                reasoningEffort: text(statement, 4) ?? "Unavailable",
                role: text(statement, 5),
                tokensUsed: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 6)),
                updatedAt: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 7)) / 1_000),
                isActive: sqlite3_column_int(statement, 8) != 0
            )
        }.filter { !$0.id.isEmpty }
    }

    func edgesIfAvailable() -> [SpawnEdge] {
        guard hasTable("thread_spawn_edges") else { return [] }
        return query("SELECT parent_thread_id, child_thread_id, status FROM thread_spawn_edges") { statement in
            guard let parentID = text(statement, 0), let childID = text(statement, 1) else { return nil }
            return SpawnEdge(parentID: parentID, childID: childID, status: text(statement, 2))
        }.compactMap { $0 }
    }

    private func displayNameExpression(_ columns: Set<String>) -> String {
        var candidates: [String] = []
        if columns.contains("name") { candidates.append(codexDisplayText("name")) }
        if columns.contains("title") { candidates.append(codexDisplayText("title")) }
        if candidates.isEmpty { return "NULL" }
        if candidates.count == 1 { return candidates[0] }
        return "COALESCE(\(candidates.joined(separator: ", ")))"
    }

    private func codexDisplayText(_ column: String) -> String {
        let trimCharacters = ([9, 10, 11, 12, 13, 32, 160, 5760] + Array(8192...8202) + [8232, 8233, 8239, 8287, 12288, 65279])
            .map { "CHAR(\($0))" }
            .joined(separator: " || ")
        return "NULLIF(TRIM(\(column), \(trimCharacters)), '')"
    }

    private func optionalColumn(_ column: String, columns: Set<String>) -> String {
        columns.contains(column) ? column : "NULL"
    }

    private func scalar(_ sql: String, bind value: String) -> String? {
        guard let statement = prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, value, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
    }

    private func strings(_ sql: String, column: Int32) -> [String] {
        query(sql) { text($0, column) }.compactMap { $0 }
    }

    private func query<T>(_ sql: String, transform: (OpaquePointer) -> T) -> [T] {
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(transform(statement)) }
        return result
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }
}

private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: value)
}

private func workspaceName(_ path: String) -> String {
    guard path != "__unknown_workspace__" else { return "Unknown workspace" }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    if url == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL { return "Home" }
    return url.lastPathComponent.isEmpty ? "Root" : url.lastPathComponent
}

private func normalizedWorkspacePath(_ path: String) -> String {
    path == "__unknown_workspace__" ? path : URL(fileURLWithPath: path).standardizedFileURL.path
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
