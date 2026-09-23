import Foundation
import SQLite3

enum StoreError: Error, CustomStringConvertible {
    case unavailable(String)
    var description: String {
        switch self { case .unavailable(let message): message }
    }
}

final class MonitorDatabase {
    private var handle: OpaquePointer?
    init(_ path: String, readOnly: Bool = true) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle); handle = nil
            throw StoreError.unavailable("数据库暂不可读")
        }
        sqlite3_busy_timeout(handle, 250)
        if readOnly { try execute("PRAGMA query_only=ON") }
    }
    deinit { sqlite3_close(handle) }
    func rows(_ sql: String, _ bindings: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.unavailable("数据库查询不可用（SQLite \(sqlite3_extended_errcode(handle))）")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var result: [[String: String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw StoreError.unavailable("数据库读取中断（SQLite \(sqlite3_extended_errcode(handle))），保留上次快照") }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let name = sqlite3_column_name(statement, index), let value = sqlite3_column_text(statement, index) {
                    row[String(cString: name)] = String(cString: value)
                }
            }
            result.append(row)
        }
    }
    func execute(_ sql: String, _ bindings: [String] = []) throws { _ = try rows(sql, bindings) }
    func columns(_ table: String) throws -> Set<String> { Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"] }) }
}

struct ObservationSource {
    let home: URL
    func database(_ prefix: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(prefix + "_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.first
    }

    func catalog() throws -> [SessionSummary] {
        guard let path = database("state") else { throw StoreError.unavailable("未找到 Codex 会话索引，请检查数据目录") }
        let db = try MonitorDatabase(path.path)
        let columns = try db.columns("threads")
        guard columns.contains("id") else { throw StoreError.unavailable("会话索引缺少标识字段") }
        let wanted = ["id", "name", "title", "preview", "cwd", "source", "thread_source", "model", "reasoning_effort",
                      "agent_nickname", "rollout_path", "archived", "updated_at_ms", "updated_at", "recency_at_ms"]
        let selection = wanted.map { field in
            guard columns.contains(field) else { return "NULL AS \(field)" }
            // Older catalogs store entire first prompts in title/preview. Keep the directory
            // lightweight; complete messages remain available in the paged trajectory.
            return ["name", "title", "preview"].contains(field) ? "substr(\(field),1,256) AS \(field)" : field
        }.joined(separator: ",")
        let rows = try db.rows("SELECT \(selection) FROM threads")
        var parents: [String: String] = [:]
        if !(try db.columns("thread_spawn_edges")).isEmpty {
            for row in try db.rows("SELECT parent_thread_id,child_thread_id FROM thread_spawn_edges") {
                if let child = row["child_thread_id"], let parent = row["parent_thread_id"], child != parent { parents[child] = parent }
            }
        }
        return rows.compactMap { row in
            guard let id = row["id"] else { return nil }
            let title = [row["name"], row["preview"], row["title"]].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? id
            let ms = max(Double(row["updated_at_ms"] ?? "") ?? (Double(row["updated_at"] ?? "") ?? 0) * 1000,
                         Double(row["recency_at_ms"] ?? "") ?? 0)
            return SessionSummary(id: id, title: title,
                workspace: row["cwd"].map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "未知项目",
                source: row["thread_source"] ?? row["source"] ?? "未知来源",
                model: row["model"] ?? "未知模型", effort: row["reasoning_effort"] ?? "未知",
                nickname: row["agent_nickname"], parentID: parents[id], rolloutPath: row["rollout_path"],
                archived: row["archived"] == "1", updatedAt: Date(timeIntervalSince1970: ms / 1000))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func latestTurns() throws -> [String: [String: String]] {
        guard let path = database("thread_history") else { return [:] }
        let db = try MonitorDatabase(path.path)
        let rows = try db.rows("""
            SELECT t.thread_id,t.turn_id,t.status,t.started_at,t.completed_at,t.error_json
            FROM thread_turns t JOIN
            (SELECT thread_id,MAX(rollout_ordinal) AS ordinal FROM thread_turns GROUP BY thread_id) n
            ON t.thread_id=n.thread_id AND t.rollout_ordinal=n.ordinal
            """)
        return Dictionary(rows.compactMap { row in row["thread_id"].map { ($0, row) } }, uniquingKeysWith: { _, new in new })
    }

    func timeline(threadID: String, before: Int64?, limit: Int = 100) throws -> TimelinePage {
        guard let path = database("thread_history") else {
            return TimelinePage(events: [], before: nil, hasMore: false, note: "此版本没有分页历史，显示已采集的日志事件")
        }
        let db = try MonitorDatabase(path.path)
        let condition = before == nil ? "" : " AND rollout_ordinal < ?"
        var bindings = [threadID]
        if let before { bindings.append(String(before)) }
        bindings.append(String(min(max(limit, 1), 500) + 1))
        let rows = try db.rows("""
            SELECT turn_id,item_id,rollout_ordinal,created_at_ms,item_json FROM thread_items
            WHERE thread_id=?\(condition) ORDER BY rollout_ordinal DESC LIMIT ?
            """, bindings)
        let selected = rows.prefix(min(max(limit, 1), 500))
        var events: [TraceEvent] = []
        for row in selected {
            guard let raw = row["item_json"], let data = raw.data(using: .utf8),
                  let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let ref = SourceReference(path: path.path, threadID: threadID, turnID: row["turn_id"], itemID: row["item_id"])
            let time = Date(timeIntervalSince1970: (Double(row["created_at_ms"] ?? "") ?? 0) / 1000)
            events.append(ObservationParser.item(item, threadID: threadID, turnID: row["turn_id"] ?? "",
                                                timestamp: time, source: ref))
        }
        return TimelinePage(events: events, before: selected.last.flatMap { Int64($0["rollout_ordinal"] ?? "") },
                            hasMore: rows.count > limit, note: nil)
    }

    static func detail(_ reference: SourceReference, characterOffset: Int = 0, pageSize: Int = 24_000, readable: Bool = false) throws -> String {
        let data: Data
        if let offset = reference.offset {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: reference.path))
            defer { try? file.close() }
            try file.seek(toOffset: offset)
            data = try file.read(upToCount: min(reference.length ?? 0, 32 * 1024 * 1024)) ?? Data()
            if let digest = reference.recordDigest, ObservationParser.digest(data) != digest {
                throw StoreError.unavailable("源记录已变化，无法用旧位置验证该证据；请刷新轨迹")
            }
        } else {
            let db = try MonitorDatabase(reference.path)
            let row = try db.rows("SELECT item_json FROM thread_items WHERE thread_id=? AND turn_id=? AND item_id=?",
                                  [reference.threadID ?? "", reference.turnID ?? "", reference.itemID ?? ""]).first
            guard let raw = row?["item_json"] else { throw StoreError.unavailable("源记录已不可用") }
            data = Data(raw.utf8)
        }
        var text = String(data: data, encoding: .utf8) ?? "内容编码不可显示"
        if var object = try? JSONSerialization.jsonObject(with: data) {
            for key in reference.jsonPointer ?? [] {
                if let dictionary = object as? [String: Any], let value = dictionary[key] { object = value }
                else if let array = object as? [Any], let index = Int(key), array.indices.contains(index) { object = array[index] }
                else { throw StoreError.unavailable("源记录中已找不到这项材料") }
            }
            let visible = visibleObject(object)
            if readable, let content = readableText(visible), !content.isEmpty { text = content }
            else if let pretty = try? JSONSerialization.data(withJSONObject: visible, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
                text = String(decoding: pretty, as: UTF8.self)
            }
        }
        let start = text.index(text.startIndex, offsetBy: min(max(characterOffset, 0), text.count))
        let end = text.index(start, offsetBy: pageSize, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end]) + (end < text.endIndex ? "\n\n—— 本页结束，可加载下一页 ——" : "")
    }
    private static func readableText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let array = value as? [Any] { return array.compactMap(readableText).joined(separator: "\n\n") }
        guard let object = value as? [String: Any] else { return nil }
        if let nested = object["payload"] ?? object["item"] { return readableText(nested) }
        for key in ["aggregatedOutput", "aggregated_output", "output", "result", "text", "content", "summary", "message", "arguments", "input", "changes"] {
            if let nested = object[key], let text = readableText(nested), !text.isEmpty { return text }
        }
        return nil
    }
    private static func visibleObject(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, pair in
                if ["encrypted_content", "raw_content", "rawContent"].contains(pair.key) {
                    result[pair.key] = "未展示内部内容"
                } else if ["image_url", "image_data"].contains(pair.key) {
                    result[pair.key] = "图像内容省略"
                } else { result[pair.key] = visibleObject(pair.value) }
            }
        }
        if let array = value as? [Any] { return array.map(visibleObject) }
        return value
    }
}

final class ObservationCache {
    let db: MonitorDatabase
    let since: Date
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try MonitorDatabase(directory.appendingPathComponent("monitor.sqlite").path, readOnly: false)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS checkpoints(thread_id TEXT PRIMARY KEY,state TEXT NOT NULL)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS usage(thread_id TEXT NOT NULL,response_id TEXT NOT NULL,time REAL NOT NULL,
            total INTEGER NOT NULL,PRIMARY KEY(thread_id,response_id))
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS usage_time ON usage(time)")
        try db.execute("CREATE TABLE IF NOT EXISTS seen(id TEXT PRIMARY KEY)")
        if let value = try db.rows("SELECT value FROM metadata WHERE key='since'").first?["value"], let time = Double(value) {
            since = Date(timeIntervalSince1970: time)
        } else {
            since = Date()
            try db.execute("INSERT INTO metadata VALUES('since',?)", [String(since.timeIntervalSince1970)])
        }
        try db.execute("DELETE FROM usage WHERE time < ?", [String(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970)])
    }
    func load(_ id: String) throws -> RolloutState? {
        guard let raw = try db.rows("SELECT state FROM checkpoints WHERE thread_id=?", [id]).first?["state"] else { return nil }
        // A cache from a different parser version can be rebuilt from the read-only source.
        return try? JSONDecoder().decode(RolloutState.self, from: Data(raw.utf8))
    }
    func checkpointIDs() throws -> [String] {
        try db.rows("SELECT thread_id FROM checkpoints").compactMap { $0["thread_id"] }
    }
    func save(_ state: RolloutState, newUsage: [UsageSample]) throws {
        let data = try JSONEncoder().encode(state)
        try db.execute("BEGIN IMMEDIATE")
        do {
            try db.execute("INSERT OR REPLACE INTO checkpoints(thread_id,state) VALUES(?,?)",
                           [state.threadID, String(decoding: data, as: UTF8.self)])
            for usage in newUsage where usage.timestamp >= since && usage.timestamp > Date().addingTimeInterval(-30 * 86400) {
                try db.execute("INSERT OR IGNORE INTO usage VALUES(?,?,?,?)",
                               [usage.threadID, usage.id, String(usage.timestamp.timeIntervalSince1970), String(usage.tokens.total)])
            }
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
    }
    func observedTotal() throws -> Int64 {
        Int64(try db.rows("SELECT COALESCE(SUM(total),0) AS total FROM usage WHERE time>=?",
                         [String(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970)]).first?["total"] ?? "") ?? 0
    }
    func markSeen(_ id: String) throws { try db.execute("INSERT OR IGNORE INTO seen VALUES(?)", [id]) }
    func seenIDs() throws -> Set<String> { Set(try db.rows("SELECT id FROM seen").compactMap { $0["id"] }) }
}
