import CodexAgentMonitor
import Foundation

do {
    try FixtureChecks.run()
    print("Fixture checks passed")
} catch {
    fputs("Fixture check failed: \(error)\n", stderr)
    exit(1)
}

private enum FixtureChecks {
    static func run() throws {
        try verifiesTreeAndRuntimeMetadata()
        try verifiesMissingColumnsDegradeSafely()
        try verifiesTitleIsNeverReadAsBusinessName()
        try verifiesWorkspaceNeverReplacesSessionIdentity()
        try verifiesOnlyRecentlyActiveSessionsRemain()
        try verifiesUpdatedHeartbeatKeepsExecutingSessionActive()
        try verifiesMainAndSubagentActivityMetadata()
        try verifiesUnsafeNameDoesNotBecomeActivity()
        try verifiesUnicodeLineSeparatorDoesNotBecomeActivity()
        try verifiesSubagentIdentityStaysSeparateWithoutNickname()
        try verifiesSessionAndSubagentIdentityDoNotCollapseToWorkspace()
        try verifiesActiveDescendantPreservesItsMainSession()
        try verifiesSafeSessionTitleFallback()
        try verifiesAutoReviewThreadsAreExcluded()
        try verifiesWorkspaceSectionsGroupMainSessions()
        try verifiesAgentPathFallbackWithoutSpawnEdges()
    }

    private static func verifiesTreeAndRuntimeMetadata() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, model TEXT, reasoning_effort TEXT, agent_role TEXT, agent_path TEXT, tokens_used INTEGER, updated_at_ms INTEGER, recency_at_ms INTEGER, archived INTEGER);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT PRIMARY KEY, status TEXT NOT NULL);
        INSERT INTO threads VALUES ('root', 'Deploy monitor', 'legacy title', 'gpt-5.6-sol', 'high', 'root', '/root', 120, 1000, \(now), 0);
        INSERT INTO threads VALUES ('child', 'Inspect schema', 'legacy title', 'gpt-5.6-terra', 'medium', 'explorer', '/root/schema', 40, 2000, \(now), 0);
        INSERT INTO thread_spawn_edges VALUES ('root', 'child', 'open');
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let snapshot = SQLiteAgentStore().load(at: database)
        try expect(snapshot.roots.count == 1, "expected one root")
        let root = try value(snapshot.roots.first, "missing root")
        try expect(root.name == "Deploy monitor", "wrong root name")
        try expect(root.model == "gpt-5.6-sol" && root.reasoningEffort == "high", "root did not use runtime model metadata")
        let child = try value(root.children.first, "missing child")
        try expect(child.name == "Sub-agent", "unnamed child must use a neutral identity")
        try expect(child.activity == "Inspect schema", "child task must remain available as activity")
        try expect(child.model == "gpt-5.6-terra" && child.reasoningEffort == "medium", "child did not use runtime model metadata")
        try expect(child.lifecycle == "open", "missing lifecycle")
    }

    private static func verifiesMissingColumnsDegradeSafely() throws {
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, archived INTEGER);
        INSERT INTO threads VALUES ('only', NULL, 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let snapshot = SQLiteAgentStore().load(at: database)
        try expect(snapshot.roots.isEmpty, "missing activity metadata must fail closed")
        try expect(!snapshot.diagnostics.isEmpty, "missing activity metadata needs a clear diagnostic")
    }

    private static func verifiesTitleIsNeverReadAsBusinessName() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('only', NULL, 'first line of prompt\nprivate prompt body must not be displayed', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let snapshot = SQLiteAgentStore().load(at: database)
        let root = try value(snapshot.roots.first, "missing privacy fallback root")
        try expect(root.name == "Main session", "thread title must never become a business name")
    }

    private static func verifiesWorkspaceNeverReplacesSessionIdentity() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, cwd TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('only', NULL, 'prompt heading\nlong user input must not be displayed', '/workspaces/campaign-engine', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let snapshot = SQLiteAgentStore().load(at: database)
        let root = try value(snapshot.roots.first, "missing workspace fallback root")
        try expect(root.name == "Main session", "workspace must remain separate from session identity")
    }

    private static func verifiesOnlyRecentlyActiveSessionsRemain() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('active', '/workspaces/monitor', \(now), 0);
        INSERT INTO threads VALUES ('stale', '/workspaces/monitor', \(now - 3_600_000), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let snapshot = SQLiteAgentStore().load(at: database)
        try expect(snapshot.roots.map(\.id) == ["active"], "stale sessions must be filtered out")
    }

    private static func verifiesUpdatedHeartbeatKeepsExecutingSessionActive() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let stale = now - 3_600_000
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, updated_at_ms INTEGER, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('executing', '/workspaces/monitor', \(now), \(stale), 0);
        INSERT INTO threads VALUES ('stale', '/workspaces/monitor', \(stale), \(stale), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let roots = SQLiteAgentStore().load(at: database).roots
        try expect(roots.map(\.id) == ["executing"], "updated heartbeat must retain the executing session without retaining stale sessions")
        try expect(roots.first?.updatedAt?.timeIntervalSince1970 == TimeInterval(now) / 1_000, "displayed activity time must use the latest heartbeat")
    }

    private static func verifiesMainAndSubagentActivityMetadata() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, agent_nickname TEXT, recency_at_ms INTEGER, archived INTEGER);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT PRIMARY KEY, status TEXT NOT NULL);
        INSERT INTO threads VALUES ('root', 'Publish monitor', NULL, NULL, \(now), 0);
        INSERT INTO threads VALUES ('child', 'Inspect icon alpha', NULL, 'Laplace', \(now), 0);
        INSERT INTO threads VALUES ('private-child', NULL, 'prompt heading\nprivate body', 'Noether', \(now), 0);
        INSERT INTO thread_spawn_edges VALUES ('root', 'child', 'open');
        INSERT INTO thread_spawn_edges VALUES ('root', 'private-child', 'open');
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database).roots.first, "missing activity root")
        try expect(root.activity == "Publish monitor", "main Agent activity must use the safe session name")
        try expect(root.children[0].name == "Laplace", "sub-Agent identity must keep its runtime nickname")
        try expect(root.children[0].activity == "Inspect icon alpha", "sub-Agent activity must use its safe thread name")
        try expect(root.children[1].activity == nil, "unsafe multiline title must not become sub-Agent activity")
    }

    private static func verifiesUnsafeNameDoesNotBecomeActivity() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('root', 'heading\nprivate body', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database).roots.first, "missing unsafe-name root")
        try expect(root.name == "Main session", "multiline name must not become session identity")
        try expect(root.activity == nil, "multiline name must not become activity")
    }

    private static func verifiesUnicodeLineSeparatorDoesNotBecomeActivity() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let separator = "\u{2028}"
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('root', 'heading\(separator)private body', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database).roots.first, "missing Unicode-separator root")
        try expect(root.name == "Main session", "Unicode line separator must not become session identity")
        try expect(root.activity == nil, "Unicode line separator must not become activity")
    }

    private static func verifiesSubagentIdentityStaysSeparateWithoutNickname() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, agent_nickname TEXT, recency_at_ms INTEGER, archived INTEGER);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT PRIMARY KEY, status TEXT NOT NULL);
        INSERT INTO threads VALUES ('root', 'Parent task', NULL, \(now), 0);
        INSERT INTO threads VALUES ('child', 'Inspect schema', NULL, \(now), 0);
        INSERT INTO thread_spawn_edges VALUES ('root', 'child', 'open');
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let child = try value(SQLiteAgentStore().load(at: database).roots.first?.children.first, "missing unnamed child")
        try expect(child.name == "Sub-agent", "task text must not become sub-Agent identity")
        try expect(child.activity == "Inspect schema", "task text must remain available as sub-Agent activity")
    }

    private static func verifiesSessionAndSubagentIdentityDoNotCollapseToWorkspace() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, agent_nickname TEXT, cwd TEXT, recency_at_ms INTEGER, archived INTEGER);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT PRIMARY KEY, status TEXT NOT NULL);
        INSERT INTO threads VALUES ('root-session', NULL, NULL, '/workspaces/campaign-engine', \(now), 0);
        INSERT INTO threads VALUES ('child-session', 'Misleading thread label', 'Laplace', '/workspaces/campaign-engine', \(now), 0);
        INSERT INTO thread_spawn_edges VALUES ('root-session', 'child-session', 'open');
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database).roots.first, "missing active root")
        try expect(root.name == "Main session", "workspace must not replace main-session identity")
        try expect(root.children.first?.name == "Laplace", "runtime nickname must identify the sub-Agent")
    }

    private static func verifiesActiveDescendantPreservesItsMainSession() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, agent_nickname TEXT, recency_at_ms INTEGER, archived INTEGER);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT PRIMARY KEY, status TEXT NOT NULL);
        INSERT INTO threads VALUES ('stale-root', 'Saved parent task', NULL, \(now - 3_600_000), 0);
        INSERT INTO threads VALUES ('active-child', 'Child task', 'Noether', \(now), 0);
        INSERT INTO thread_spawn_edges VALUES ('stale-root', 'active-child', 'open');
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database).roots.first, "active child lost its main session")
        try expect(root.id == "stale-root", "wrong ancestor root")
        try expect(!root.isActive, "stale ancestor must not be reported as directly active")
        try expect(root.currentActivity == nil, "inactive ancestor must not present saved activity as current work")
        try expect(root.children.map(\.id) == ["active-child"], "active child missing from preserved tree")
        try expect(root.children.first?.isActive == true, "recent child must remain directly active")
        try expect(root.children.first?.currentActivity == "Child task", "active child must expose current activity")
    }

    private static func verifiesSafeSessionTitleFallback() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('named', NULL, 'Fix active session monitor', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database).roots.first, "missing titled session")
        try expect(root.name == "Fix active session monitor", "safe session title was not used")
    }

    private static func verifiesAutoReviewThreadsAreExcluded() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, model TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('user-session', 'gpt-5.6-sol', \(now), 0);
        INSERT INTO threads VALUES ('guardian', 'codex-auto-review', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let roots = SQLiteAgentStore().load(at: database).roots
        try expect(roots.map(\.id) == ["user-session"], "internal auto-review thread must be excluded")
        try expect(roots.first?.model == "gpt-5.6-sol", "runtime model was changed")
    }

    private static func verifiesWorkspaceSectionsGroupMainSessions() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('campaign-a', '/workspaces/main/campaign-engine', \(now), 0);
        INSERT INTO threads VALUES ('campaign-b', '/worktrees/feature/campaign-engine', \(now), 0);
        INSERT INTO threads VALUES ('billing-a', '/workspaces/billing-service', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let workspaces = SQLiteAgentStore().load(at: database).workspaces
        try expect(workspaces.map(\.name) == ["campaign-engine", "billing-service"], "wrong workspace sections")
        try expect(workspaces[0].sessions.map(\.id) == ["campaign-a", "campaign-b"], "same-workspace sessions were not grouped")
        try expect(workspaces[1].sessions.map(\.id) == ["billing-a"], "second workspace session missing")
    }

    private static func verifiesAgentPathFallbackWithoutSpawnEdges() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, agent_nickname TEXT, cwd TEXT, agent_path TEXT, model TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('root', 'Monitor sessions', NULL, '/workspaces/monitor', NULL, 'gpt-5.6-sol', \(now), 0);
        INSERT INTO threads VALUES ('child', NULL, 'Noether', '/workspaces/monitor', '/root/gpt_5_6_terra_inspect_runtime', 'gpt-5.6-terra', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let roots = SQLiteAgentStore().load(at: database).roots
        try expect(roots.map(\.id) == ["root"], "agent_path fallback did not preserve the main session")
        try expect(roots.first?.children.map(\.id) == ["child"], "agent_path fallback did not attach the sub-Agent")
        try expect(roots.first?.children.first?.activity == "Inspect runtime", "agent_path task fallback did not expose what the sub-Agent is doing")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckError.failed(message) }
    }

    private static func value<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CheckError.failed(message) }
        return value
    }

    private enum CheckError: Error { case failed(String) }
}

private enum FixtureDatabase {
    static func make(sql: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-monitor-\(UUID().uuidString).sqlite")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError.sqliteFailed }
        return url
    }

    private enum FixtureError: Error { case sqliteFailed }
}
