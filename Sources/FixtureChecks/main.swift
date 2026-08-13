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
        try verifiesResponsivePanelBoundaries()
        try verifiesMissingSelectionFallsBackToFirstSession()
        try verifiesCodexRuntimeTitlePriority()
        try verifiesAppServerRequestTimeoutState()
        try verifiesTreeAndRuntimeMetadata()
        try verifiesMissingColumnsDegradeSafely()
        try verifiesAppServerTitleOverridesSQLiteFallback()
        try verifiesSQLiteFallbackIsNotCustomTruncated()
        try verifiesBlankPreviewUsesFullThreadIdentifier()
        try verifiesWorkspaceNeverReplacesSessionIdentity()
        try verifiesOnlyRecentlyActiveSessionsRemain()
        try verifiesUpdatedHeartbeatKeepsExecutingSessionActive()
        try verifiesMainAndSubagentActivityMetadata()
        try verifiesNameMatchesCodexDisplayTitle()
        try verifiesUnicodeLineSeparatorIsPreserved()
        try verifiesSubagentIdentityStaysSeparateWithoutNickname()
        try verifiesSessionAndSubagentIdentityDoNotCollapseToWorkspace()
        try verifiesActiveDescendantPreservesItsMainSession()
        try verifiesSQLiteTitleProvidesFallback()
        try verifiesAutoReviewThreadsAreExcluded()
        try verifiesWorkspaceSectionsGroupMainSessions()
        try verifiesAgentPathFallbackWithoutSpawnEdges()
    }

    private static func verifiesResponsivePanelBoundaries() throws {
        try expect(MonitorPanelLayout.mode(forWidth: 899) == .compact, "899pt must preserve the compact single-column panel")
        try expect(MonitorPanelLayout.mode(forWidth: 900) == .overview, "900pt must enable the overview grid")
        try expect(MonitorPanelLayout.mode(forWidth: 1_279) == .overview, "1279pt must remain in overview mode")
        try expect(MonitorPanelLayout.mode(forWidth: 1_280) == .inspector, "1280pt must enable the session inspector")
    }

    private static func verifiesMissingSelectionFallsBackToFirstSession() throws {
        try expect(
            MonitorPanelLayout.resolvedSelection(preferredID: "missing", availableIDs: ["active-a", "active-b"]) == "active-a",
            "a stale selection must fall back to the first active session"
        )
        try expect(
            MonitorPanelLayout.resolvedSelection(preferredID: "active-b", availableIDs: ["active-a", "active-b"]) == "active-b",
            "a valid selection must be preserved"
        )
        try expect(
            MonitorPanelLayout.resolvedSelection(preferredID: nil, availableIDs: []) == nil,
            "an empty snapshot must not invent a selection"
        )
    }

    private static func verifiesCodexRuntimeTitlePriority() throws {
        try expect(
            CodexRuntimeTitle.resolve(threadID: "thread-id", name: "  Renamed task  ", preview: "First prompt") == "Renamed task",
            "app-server name must be the first title source"
        )
        try expect(
            CodexRuntimeTitle.resolve(threadID: "thread-id", name: nil, preview: "  First prompt\ncontinued  ") == "First prompt\ncontinued",
            "app-server preview must be preserved after outer trimming"
        )
        try expect(
            CodexRuntimeTitle.resolve(threadID: "thread-id", name: " \n ", preview: nil) == "thread-id",
            "missing app-server metadata must use the full thread identifier"
        )
    }

    private static func verifiesAppServerRequestTimeoutState() throws {
        var state = AppServerRequestState()
        let oldProcessRequest = try value(state.startNext(), "first app-server request must start")
        try expect(state.startNext() == nil, "a second request must not replace an outstanding request")
        try expect(state.expire(oldProcessRequest), "the matching stalled request must expire")
        let newProcessRequest = try value(state.startNext(), "restart must allocate another request")
        try expect(newProcessRequest != oldProcessRequest, "request IDs must never be reused across process generations")
        try expect(!state.finish(oldProcessRequest), "an old-process response must not clear the new request")
        try expect(state.expire(newProcessRequest), "the new matching stalled request must expire")
        try expect(state.requestID == nil, "expiry must release the request gate for the next refresh")
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

    private static func verifiesAppServerTitleOverridesSQLiteFallback() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, preview TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('only', NULL, 'stale SQLite title', 'first user message', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let snapshot = SQLiteAgentStore().load(at: database, runtimeTitles: ["only": "Actual Codex title"])
        let root = try value(snapshot.roots.first, "missing runtime-title root")
        try expect(root.name == "Actual Codex title", "app-server title must override the SQLite fallback")
        try expect(root.activity == "Actual Codex title", "session activity must use the same app-server title")
    }

    private static func verifiesSQLiteFallbackIsNotCustomTruncated() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let longTitle = String(repeating: "x", count: 81)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('only', '\(longTitle)', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database).roots.first, "missing long-title root")
        try expect(root.name == longTitle, "SQLite fallback title must not be custom-truncated")
        try expect(root.activity == longTitle, "activity must preserve the same fallback title")
    }

    private static func verifiesBlankPreviewUsesFullThreadIdentifier() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let horizontalWhitespace = "\t\u{00A0}\u{3000}"
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, preview TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('tab-only', '\(horizontalWhitespace)', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database).roots.first, "missing whitespace-title root")
        try expect(root.name == "tab-only", "blank Codex metadata must use the full thread identifier")
        try expect(root.activity == nil, "missing Codex title must not invent current activity")
    }

    private static func verifiesWorkspaceNeverReplacesSessionIdentity() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, preview TEXT, cwd TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('only', NULL, 'SQLite fallback title', 'first user message', '/workspaces/campaign-engine', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let snapshot = SQLiteAgentStore().load(at: database)
        let root = try value(snapshot.roots.first, "missing workspace fallback root")
        try expect(root.name == "SQLite fallback title", "workspace must not replace the session title")
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
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, preview TEXT, agent_nickname TEXT, recency_at_ms INTEGER, archived INTEGER);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT PRIMARY KEY, status TEXT NOT NULL);
        INSERT INTO threads VALUES ('root', 'Publish monitor', NULL, NULL, NULL, \(now), 0);
        INSERT INTO threads VALUES ('child', 'Inspect icon alpha', NULL, NULL, 'Laplace', \(now), 0);
        INSERT INTO threads VALUES ('private-child', NULL, 'stale SQLite title', 'Codex preview', 'Noether', \(now), 0);
        INSERT INTO thread_spawn_edges VALUES ('root', 'child', 'open');
        INSERT INTO thread_spawn_edges VALUES ('root', 'private-child', 'open');
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database, runtimeTitles: ["private-child": "Codex preview"]).roots.first, "missing activity root")
        try expect(root.activity == "Publish monitor", "main Agent activity must use the Codex session name")
        try expect(root.children[0].name == "Laplace", "sub-Agent identity must keep its runtime nickname")
        try expect(root.children[0].activity == "Inspect icon alpha", "sub-Agent activity must use its Codex thread name")
        try expect(root.children[1].activity == "Codex preview", "sub-Agent activity must fall back to Codex preview")
    }

    private static func verifiesNameMatchesCodexDisplayTitle() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('root', 'heading\nprivate body', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database).roots.first, "missing unsafe-name root")
        try expect(root.name == "heading\nprivate body", "Codex name must be preserved after outer trimming")
        try expect(root.activity == "heading\nprivate body", "activity must preserve the same Codex name")
    }

    private static func verifiesUnicodeLineSeparatorIsPreserved() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let separator = "\u{2028}"
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('root', 'heading\(separator)private body', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database).roots.first, "missing Unicode-separator root")
        try expect(root.name == "heading\(separator)private body", "SQLite fallback must preserve internal Unicode separators")
        try expect(root.activity == "heading\(separator)private body", "activity must preserve internal Unicode separators")
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
        try expect(root.name == "root-session", "missing metadata must use the full Codex thread identifier")
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

    private static func verifiesSQLiteTitleProvidesFallback() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let database = try FixtureDatabase.make(sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, preview TEXT, recency_at_ms INTEGER, archived INTEGER);
        INSERT INTO threads VALUES ('named', NULL, 'stale SQLite title', 'Fix active session monitor', \(now), 0);
        """)
        defer { try? FileManager.default.removeItem(at: database) }

        let root = try value(SQLiteAgentStore().load(at: database).roots.first, "missing titled session")
        try expect(root.name == "stale SQLite title", "SQLite title must provide a fallback when app-server is unavailable")
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
