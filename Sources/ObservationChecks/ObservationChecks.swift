import Foundation
import SessionAtlasCore

@MainActor
final class ObservationTests {
    func testLocalizationCatalogAndSourceArguments() async throws {
        let issues = Localization.catalogIssues()
        if !issues.isEmpty { print("Localization catalog issues: \(issues)") }
        try expectEqual(issues, [])
        try expectEqual(AppLanguage.resolve(preferredLanguages: ["zh-Hant-TW", "en"]), .simplifiedChinese)
        try expectEqual(AppLanguage.resolve(preferredLanguages: ["en-US", "zh-Hans"]), .english)
        try expectEqual(AppLanguage.resolve(preferredLanguages: ["fr-FR"]), .english)
        for state in ExecutionState.allCases {
            try expectNotEqual(L(state.label, language: .english), state.label)
            try expectEqual(L(state.label, language: .simplifiedChinese), state.label)
        }
        for category in ContextCategory.allCases {
            try expectNotEqual(L(category.label, language: .english), category.label)
            try expectNotEqual(L(category.explanation, language: .english), category.explanation)
        }
        try expectEqual(L("已加载 125 条 · 匹配 3 条", language: .english), "Loaded: 125 · Matching: 3")
        try expectEqual(L("调用请求 · 用户输入 🚀 {0} $1\noriginal", language: .english), "Call requested · 用户输入 🚀 {0} $1\noriginal")
        try expectEqual(L("第 2 次压缩后", language: .english), "After compaction 2")
        try expectEqual(Localization.diagnostic("无法读取源记录：源记录已不可用", language: .english), "Cannot read source record: Source record no longer available")
    }

    func testLocalizedCachedEvidencePreservesSourceText() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        try fixture.state.execute("UPDATE threads SET name='用户输入' WHERE id='one'")
        try fixture.append("one", type: "event_msg", payload: ["type": "task_started", "turn_id": "t"])
        try fixture.tool("one", id: "source-named-tool", status: "completed", name: "失败")
        try fixture.append("one", type: "event_msg", payload: ["type": "item_completed", "turn_id": "t",
            "item": ["type": "agentMessage", "id": "reply", "text": "用户输入", "status": "completed"]])
        try fixture.append("one", type: "event_msg", payload: ["type": "task_complete", "turn_id": "t", "error": ["message": "已确认"]])
        let engine = fixture.engine()
        let result = await engine.poll(selectedID: "one")
        try expectEqual(result.sessions.first?.title, "用户输入")
        let observation = await engine.observation("one")
        let tool = try requireValue(observation.events.first { $0.id == "source-named-tool" })
        let reply = try requireValue(observation.events.first { $0.id == "reply" })
        try expectEqual(tool.localizedTitle(language: .english), "失败")
        try expectEqual(reply.localizedTitle(language: .english), "Assistant reply")
        try expectEqual(reply.localizedPreview(language: .english), "用户输入")
        let alert = try requireValue(result.attention.first { $0.rule == "failure" })
        try expectEqual(alert.localizedExplanation(language: .english), "已确认")
        let decoded = try JSONDecoder().decode(TraceEvent.self, from: JSONEncoder().encode(tool))
        try expectEqual(decoded.localizedTitle(language: .english), "失败")
        await engine.stop()
        let reopened = fixture.engine()
        _ = await reopened.poll(selectedID: "one")
        let cached = await reopened.observation("one")
        try expectEqual(cached.events.first { $0.id == "reply" }?.localizedTitle(language: .english), "Assistant reply")
        try expectEqual(cached.events.first { $0.id == "reply" }?.localizedTitle(language: .simplifiedChinese), "助手回复")
    }

    func testLocalizedMaterialAndDetailPagination() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        let original = "本页结束 用户输入 失败 🚀 " + String(repeating: "原文", count: 13_000)
        try fixture.append("one", type: "response_item", payload: ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": original]]])
        try fixture.append("one", type: "response_item", payload: ["type": "function_call", "name": "functions.exec_command", "call_id": "call", "arguments": "用户输入"])
        try fixture.append("one", type: "response_item", payload: ["type": "function_call_output", "call_id": "call", "output": "本页结束"])
        try fixture.append("one", type: "compacted", payload: ["replacement_history": [["type": "compaction", "encrypted_content": "opaque-test"]]])
        let history = await ContextExplorer().load(threadID: "one", path: fixture.log("one").path)
        let materials = history.phases.flatMap(\.materials)
        let user = try requireValue(materials.first { $0.category == .user })
        let call = try requireValue(materials.first { $0.category == .toolCall })
        let result = try requireValue(materials.first { $0.category == .toolResult })
        let summary = try requireValue(materials.first { $0.category == .summary })
        try expectEqual(user.localizedTitle(language: .english), "User input")
        try expectTrue(user.localizedPreview(language: .english).hasPrefix("本页结束 用户输入 失败"))
        try expectEqual(call.localizedTitle(language: .english), "Call · Terminal command")
        try expectNotEqual(summary.localizedPreview(language: .english), summary.preview)
        let engine = fixture.engine()
        let first = await engine.detailPage(user.source, readable: true, language: .english)
        let second = await engine.detailPage(user.source, offset: 24_000, readable: true, language: .english)
        try expectTrue(first.hasMore); try expectFalse(second.hasMore)
        try expectEqual(first.text + second.text, original)
        let short = await engine.detailPage(result.source, readable: true, language: .english)
        try expectEqual(short.text, "本页结束"); try expectFalse(short.hasMore)
        let opaque = await engine.detailPage(summary.source, language: .english)
        try expectTrue(opaque.text.contains("Internal content not displayed"))
        try expectTrue(opaque.text.contains("encrypted_content"))
        try expectFalse(opaque.text.contains("opaque-test"))
    }

    func testLegacyCheckpointRebuildKeepsUsageAndSeenMarkers() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        try fixture.append("one", type: "event_msg", payload: ["type": "task_started", "turn_id": "t"])
        try fixture.append("one", type: "token_usage_record", payload: usage("one", "original-response"))
        for i in 0..<3 { try fixture.tool("one", id: "retry-\(i)", status: "failed") }
        let engine = fixture.engine()
        let original = await engine.poll(selectedID: "one")
        let alert = try requireValue(original.attention.first { $0.rule == "retries" })
        await engine.markSeen(alert.id); await engine.stop()
        let cache = try FixtureConnection(fixture.root.appendingPathComponent("cache/monitor.sqlite").path, readOnly: false)
        // Remove fields absent in 0.8 checkpoints. Only parsed checkpoints should be rebuilt.
        try cache.execute("UPDATE checkpoints SET state=json_remove(state, '$.events[0].titleIsSource') WHERE thread_id='one'")
        let reopened = fixture.engine()
        let rebuilt = await reopened.poll(selectedID: "one")
        try expectEqual(rebuilt.observedTokens, original.observedTokens)
        try expectTrue(rebuilt.attention.first { $0.id == alert.id }?.seen == true)
        let events = await reopened.observation("one").events
        try expectTrue(events.contains { $0.localizedTitle(language: .english) == "Turn started" })
    }

    func testSessionOrderingUsesExecutionTimeAndStableTies() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        for id in ["old-alert", "recent", "a", "b", "fallback"] { try fixture.add(id) }
        var sessions = await fixture.engine().poll().sessions
        for i in sessions.indices {
            sessions[i].updatedAt = Date(timeIntervalSince1970: 999)
            sessions[i].lastEventAt = Date(timeIntervalSince1970: 100)
            if sessions[i].id == "recent" { sessions[i].lastEventAt = Date(timeIntervalSince1970: 300) }
            if sessions[i].id == "old-alert" { sessions[i].attentionCount = 2 }
            if sessions[i].id == "fallback" {
                sessions[i].lastEventAt = nil
                sessions[i].updatedAt = Date(timeIntervalSince1970: 200)
            }
        }
        let order = SessionListOrder(sessions)
        try expectEqual(order.sorted(sessions).map(\.id), ["recent", "fallback", "a", "b", "old-alert"])
        try expectEqual(order.sorted(sessions.reversed()).map(\.id), ["recent", "fallback", "a", "b", "old-alert"])
        try expectEqual(order.sorted(sessions, mode: .attentionFirst).first?.id, "old-alert")
        try expectEqual(order.activity(for: try requireValue(sessions.first { $0.id == "recent" })), Date(timeIntervalSince1970: 300))
    }

    func testSessionOrderingIncludesDescendantsAndGuardsCycles() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        for id in ["parent", "child", "grandchild", "other"] { try fixture.add(id) }
        var sessions = await fixture.engine().poll().sessions
        for i in sessions.indices {
            sessions[i].lastEventAt = Date(timeIntervalSince1970: 100)
            switch sessions[i].id {
            case "child": sessions[i].parentID = "parent"
            case "grandchild":
                sessions[i].parentID = "child"; sessions[i].attentionCount = 1
                sessions[i].turnStartedAt = Date(timeIntervalSince1970: 300)
            case "other": sessions[i].lastEventAt = Date(timeIntervalSince1970: 200)
            default: break
            }
        }
        let order = SessionListOrder(sessions)
        let roots = sessions.filter { $0.parentID == nil }
        try expectEqual(order.sorted(roots).map(\.id), ["parent", "other"])
        try expectEqual(order.sorted(roots, mode: .attentionFirst).first?.id, "parent")
        try expectEqual(order.activity(for: try requireValue(roots.first { $0.id == "parent" })), Date(timeIntervalSince1970: 300))
        // Malformed ancestry must not hang the list calculation.
        if let i = sessions.firstIndex(where: { $0.id == "parent" }) { sessions[i].parentID = "grandchild" }
        try expectEqual(SessionListOrder(sessions).sorted(sessions).count, 4)
    }
    func testOldInProgressIsNotLiveDespiteRecentCatalogEdits() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let now = Date()
        for id in ["old", "fresh", "finished", "archived", "future"] { try fixture.add(id, archived: id == "archived") }
        for (id, status, age) in [("old", "inProgress", 86400.0), ("fresh", "inProgress", 20.0), ("finished", "completed", 20.0), ("archived", "inProgress", 20.0), ("future", "inProgress", -86400.0)] {
            try fixture.history.execute("INSERT INTO thread_turns VALUES(?,?,1,?,?,?,NULL)",
                [id, "turn", status, String(now.addingTimeInterval(-age).timeIntervalSince1970 * 1000),
                 status == "completed" ? String(now.timeIntervalSince1970 * 1000) : ""])
        }
        let result = await fixture.engine().poll(now: now)
        try expectEqual(result.sessions.first { $0.id == "old" }?.state, .unconfirmed)
        try expectEqual(result.sessions.first { $0.id == "fresh" }?.state, .running)
        try expectEqual(result.sessions.first { $0.id == "finished" }?.state, .completed)
        try expectEqual(result.sessions.first { $0.id == "future" }?.state, .unconfirmed)
        try expectEqual(result.sessions.filter(\.isRecentlyActive).map(\.id), ["fresh"])
    }

    func testActivityExpiresAndRecoversWithoutInventingCompletion() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let now = Date()
        try fixture.add("one", log: true)
        try fixture.append("one", type: "event_msg", payload: ["type": "task_started", "turn_id": "t"])
        let engine = fixture.engine()
        let fresh = await engine.poll(selectedID: "one", now: now)
        try expectEqual(fresh.sessions.first?.state, .running)
        let stale = await engine.poll(selectedID: "one", now: now.addingTimeInterval(301))
        try expectEqual(stale.sessions.first?.state, .unconfirmed)
        let event: [String: Any] = ["type": "response_item", "timestamp": now.addingTimeInterval(302).timeIntervalSince1970,
            "payload": ["type": "function_call", "name": "sample", "call_id": "c", "arguments": "{}"]]
        try fixture.write("one", data: JSONSerialization.data(withJSONObject: event) + Data([10]))
        let resumed = await engine.poll(selectedID: "one", now: now.addingTimeInterval(303))
        try expectEqual(resumed.sessions.first?.state, .running)
        try expectTrue(resumed.sessions.first?.activityNote == nil)
        let staleAgain = await engine.poll(selectedID: "one", now: now.addingTimeInterval(603))
        try expectEqual(staleAgain.sessions.first?.state, .unconfirmed)
        let completion: [String: Any] = ["type": "event_msg", "timestamp": now.addingTimeInterval(604).timeIntervalSince1970,
            "payload": ["type": "task_complete", "turn_id": "t"]]
        try fixture.write("one", data: JSONSerialization.data(withJSONObject: completion) + Data([10]))
        let finished = await engine.poll(selectedID: "one", now: now.addingTimeInterval(605))
        try expectEqual(finished.sessions.first?.state, .completed)
        try expectTrue(finished.sessions.first?.activityNote == nil)
    }

    func testContextComparisonUsesAdjacentPositionsAndRespectsModelAndPhaseBoundaries() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        try fixture.append("one", type: "turn_context", payload: ["model": "model-a"])
        try fixture.append("one", type: "response_item", payload: ["type": "message", "role": "user", "content": [["type": "input_text", "text": "before first sample"]]])
        try fixture.append("one", type: "event_msg", payload: context(used: 200, capacity: 1000, total: 200))
        try fixture.append("one", type: "response_item", payload: ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "between samples"]]])
        try fixture.append("one", type: "event_msg", payload: context(used: 350, capacity: 1000, total: 550))
        try fixture.append("one", type: "response_item", payload: ["type": "message", "role": "user", "content": [["type": "input_text", "text": "after selected sample"]]])
        try fixture.append("one", type: "turn_context", payload: ["model": "model-b"])
        try fixture.append("one", type: "event_msg", payload: context(used: 400, capacity: 1000, total: 950))
        try fixture.append("one", type: "event_msg", payload: context(used: 500, capacity: 2000, total: 1450))
        try fixture.append("one", type: "compacted", payload: ["message": "new phase summary"])
        try fixture.append("one", type: "event_msg", payload: context(used: 100, capacity: 2000, total: 1550))
        let history = await ContextExplorer().load(threadID: "one", path: fixture.log("one").path)
        let phase = try requireValue(history.phases.first)
        try expectTrue(phase.change(at: phase.checkpoints[0].id) == nil)
        let change = try requireValue(phase.change(at: phase.checkpoints[1].id))
        try expectEqual(change.tokenDelta, 150)
        try expectEqual(change.materials.map(\.preview), ["between samples"])
        try expectEqual(phase.materials(through: phase.checkpoints[1].id).count, 2)
        try expectEqual(phase.materials(through: nil).count, 3)
        try expectTrue(phase.change(at: phase.checkpoints[2].id)?.tokenDelta == nil)
        try expectTrue(phase.change(at: phase.checkpoints[3].id)?.tokenDelta == nil)
        let next = try requireValue(history.phases.last)
        try expectTrue(next.change(at: next.checkpoints[0].id) == nil)
    }

    func testCatalogCoversArchiveSystemChildrenAndDuplicateWorkspaceNames() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("root", workspace: "/work/a/shared")
        try fixture.add("child", workspace: "/work/b/shared", model: "codex-auto-review", archived: true)
        try fixture.state.execute("INSERT INTO thread_spawn_edges VALUES('root','child','open')")
        for i in 0..<205 { try fixture.add("cold-\(i)") }
        let engine = fixture.engine()
        let result = await engine.poll()
        try expectEqual(result.sessions.count, 207)
        let child = try requireValue(result.sessions.first { $0.id == "child" })
        try expectTrue(child.archived)
        try expectTrue(child.isSystem)
        try expectEqual(child.parentID, "root")
        try expectNotEqual(child.workspace, result.sessions.first { $0.id == "root" }?.workspace)
        try expectEqual(try fixture.state.rows("SELECT COUNT(*) AS n FROM threads").first?["n"], "207")
    }

    func testCatalogBoundsEmbeddedPromptMetadata() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one")
        try fixture.state.execute("UPDATE threads SET name=? WHERE id='one'", [String(repeating: "长输入", count: 40_000)])
        let engine = fixture.engine()
        let result = await engine.poll()
        try expectEqual(result.sessions.first?.title.count, 256)
    }

    func testColdCheckpointResumesWithoutSelectionAfterRestart() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("cold", log: true)
        try fixture.state.execute("UPDATE threads SET updated_at_ms=1 WHERE id='cold'")
        let engine = fixture.engine()
        _ = await engine.poll(selectedID: "cold")
        await engine.stop()
        try fixture.append("cold", type: "event_msg", payload: ["type": "task_started", "turn_id": "resumed"])
        let reopened = fixture.engine()
        let result = await reopened.poll()
        try expectEqual(result.sessions.first?.state, .running)
        try expectEqual(result.sessions.first?.turnID, "resumed")
    }

    func testContextReplacementPreservesOnlyRecordedMaterialsAndOpaqueSummary() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        try fixture.append("one", type: "response_item", payload: ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": "older input that is no longer retained"]]])
        try fixture.append("one", type: "event_msg", payload: context(used: 900, capacity: 1000, total: 900))
        let replacement: [[String: Any]] = [
            ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "retained developer rules"]]],
            ["type": "compaction", "encrypted_content": "opaque-test-value"]
        ]
        try fixture.append("one", type: "compacted", payload: ["replacement_history": replacement])
        try fixture.append("one", type: "response_item", payload: ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": "new question"]]])
        try fixture.append("one", type: "event_msg", payload: context(used: 200, capacity: 1000, total: 1100))
        let explorer = ContextExplorer()
        let result = await explorer.load(threadID: "one", path: fixture.log("one").path)
        try expectEqual(result.phases.count, 2)
        let latest = try requireValue(result.phases.last)
        try expectTrue(latest.hasReplacement)
        try expectEqual(latest.materials.count, 3)
        try expectFalse(latest.materials.contains { $0.preview.contains("older input") })
        let summary = try requireValue(latest.materials.first { $0.category == .summary })
        try expectFalse(summary.readable); try expectEqual(summary.characters, 0)
        try expectFalse(summary.preview.contains("opaque-test-value"))
        try expectEqual(latest.checkpoints.last?.ratio, 0.2)
        let retained = try requireValue(latest.materials.first { $0.category == .instructions })
        let content = await fixture.engine().detail(retained.source, readable: true)
        try expectEqual(content, "retained developer rules")
    }

    func testContextCategoriesToolResultsAndCheckpointCutoff() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        try fixture.append("one", type: "response_item", payload: ["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": "# AGENTS.md\nProject rules"],
            ["type": "input_text", "text": "<skills_instructions>Available skills</skills_instructions>"],
            ["type": "input_image", "image_url": "unused-fixture-image"]
        ]])
        try fixture.append("one", type: "response_item", payload: ["type": "function_call", "name": "functions.exec_command", "call_id": "call", "arguments": "{\"cmd\":\"cat sample.txt\"}"])
        try fixture.append("one", type: "response_item", payload: ["type": "function_call_output", "call_id": "call", "output": "actual file contents"])
        try fixture.append("one", type: "event_msg", payload: context(used: 200, capacity: 1000, total: 200))
        try fixture.append("one", type: "response_item", payload: ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "later reply"]]])
        try fixture.append("one", type: "response_item", payload: ["type": "reasoning", "content": [["type": "text", "text": "private test reasoning"]]])
        let result = await ContextExplorer().load(threadID: "one", path: fixture.log("one").path)
        let phase = try requireValue(result.phases.first)
        try expectEqual(phase.materials.count, 6)
        try expectEqual(Set(phase.materials.map(\.category)), Set([.instructions, .skills, .attachment, .toolCall, .toolResult, .assistant]))
        let returned = try requireValue(phase.materials.first { $0.category == .toolResult })
        try expectTrue(returned.title.contains("终端命令"))
        let content = await fixture.engine().detail(returned.source, readable: true)
        try expectEqual(content, "actual file contents")
        let cutoff = try requireValue(phase.checkpoints.first?.id)
        try expectEqual(phase.materials.filter { $0.recordOffset <= cutoff }.count, 5)
        try expectFalse(phase.materials.contains { $0.preview.contains("private test reasoning") })
    }

    func testContextIncrementalIndexAndMissingReplacementRemainExplicit() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        for i in 0..<25 {
            try fixture.append("one", type: "response_item", payload: ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "message \(i) " + String(repeating: "a", count: 200)]]])
        }
        let explorer = ContextExplorer()
        var result = await explorer.load(threadID: "one", path: fixture.log("one").path, byteBudget: 1024)
        try expectFalse(result.complete)
        for _ in 0..<20 where !result.complete { result = await explorer.load(threadID: "one", path: fixture.log("one").path, byteBudget: 1024) }
        try expectTrue(result.complete)
        try expectEqual(result.phases.first?.materials.count, 25)
        let again = await explorer.load(threadID: "one", path: fixture.log("one").path)
        try expectEqual(again.phases.first?.materials.count, 25)
        try fixture.append("one", type: "compacted", payload: ["message": "visible compact summary"])
        let compacted = await explorer.load(threadID: "one", path: fixture.log("one").path)
        try expectFalse(compacted.phases.last?.hasReplacement ?? true)
        try expectEqual(compacted.phases.last?.materials.count, 1)
        try expectEqual(compacted.phases.last?.materials.first?.preview, "visible compact summary")
    }

    func testIncrementalUsageDedupAndRestart() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        let engine = fixture.engine()
        _ = await engine.poll(selectedID: "one")
        try fixture.append("one", type: "event_msg", payload: ["type": "task_started", "turn_id": "t1"])
        try fixture.append("one", type: "token_usage_record", payload: usage("one", "r1"))
        try fixture.append("one", type: "token_usage_record", payload: usage("one", "r1"))
        let first = await engine.poll(selectedID: "one")
        try expectEqual(first.observedTokens, 120)
        try expectEqual(first.sessions.first?.state, .running)
        let observation = await engine.observation("one")
        try expectEqual(observation.usage.count, 1)
        await engine.stop()
        let resumed = fixture.engine()
        let second = await resumed.poll(selectedID: "one")
        try expectEqual(second.observedTokens, 120)
        try fixture.append("one", type: "token_usage_record", payload: usage("one", "r2"))
        let third = await resumed.poll(selectedID: "one")
        try expectEqual(third.observedTokens, 240)
    }

    func testPartialLineIsNotConsumedUntilNewline() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        let engine = fixture.engine(); _ = await engine.poll(selectedID: "one")
        let object: [String: Any] = ["type": "event_msg", "timestamp": Date().timeIntervalSince1970,
                                      "payload": ["type": "task_started", "turn_id": "t"]]
        let data = try JSONSerialization.data(withJSONObject: object)
        try fixture.write("one", data: data.prefix(data.count / 2))
        let partial = await engine.poll(selectedID: "one")
        try expectEqual(partial.sessions.first?.state, .unknown)
        try fixture.write("one", data: Data(data.dropFirst(data.count / 2)) + Data([10]))
        let completed = await engine.poll(selectedID: "one")
        try expectEqual(completed.sessions.first?.state, .running)
    }

    func testContextSamplesRemainSeparateFromCumulativeUsageAndCompaction() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        try fixture.append("one", type: "turn_context", payload: ["model": "model-a", "effort": "high", "turn_id": "t"])
        try fixture.append("one", type: "event_msg", payload: context(used: 400, capacity: 1000, total: 8000))
        try fixture.append("one", type: "compacted", payload: ["message": "summary"])
        let engine = fixture.engine()
        _ = await engine.poll(selectedID: "one")
        var result = await engine.observation("one")
        try expectEqual(result.contexts.last?.used, 400)
        try expectEqual(result.cumulative?.total, 8000)
        try expectTrue(result.pendingCompaction)
        try fixture.append("one", type: "event_msg", payload: context(used: 100, capacity: 2000, total: 8100))
        _ = await engine.poll(selectedID: "one"); result = await engine.observation("one")
        try expectEqual(result.contexts.last?.ratio, 0.05)
        try expectFalse(result.pendingCompaction)
        try expectNotEqual(result.contexts.first?.segment, result.contexts.last?.segment)
    }

    func testWaitingResolutionAndToolFailureDoNotInventTurnFailure() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        try fixture.append("one", type: "event_msg", payload: ["type": "task_started", "turn_id": "t"])
        try fixture.append("one", type: "response_item", payload: ["type": "function_call", "name": "request_user_input", "call_id": "q", "arguments": "{}"])
        let engine = fixture.engine()
        let waiting = await engine.poll(selectedID: "one")
        try expectEqual(waiting.sessions.first?.state, .waiting)
        try expectFalse(waiting.sessions.first?.isRecentlyActive ?? true)
        try fixture.append("one", type: "response_item", payload: ["type": "function_call_output", "call_id": "q", "output": "answer"])
        try fixture.tool("one", id: "failed", status: "failed")
        let running = await engine.poll(selectedID: "one")
        try expectEqual(running.sessions.first?.state, .running)
        try fixture.append("one", type: "event_msg", payload: ["type": "task_complete", "turn_id": "t", "error": ["message": "failed"]])
        let failed = await engine.poll(selectedID: "one")
        try expectEqual(failed.sessions.first?.state, .failed)
        try expectTrue(failed.attention.contains { $0.rule == "failure" && $0.definite })
    }

    func testRulesMergeEvidenceExcludePollingAndResolveContextPressure() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        try fixture.append("one", type: "event_msg", payload: ["type": "task_started", "turn_id": "t"])
        for i in 0..<3 { try fixture.tool("one", id: "fail-\(i)", status: "failed") }
        let engine = fixture.engine(); let initial = await engine.poll(selectedID: "one")
        try expectEqual(initial.attention.filter { $0.rule == "retries" && !$0.resolved }.count, 1)
        for i in 0..<3 { try fixture.tool("one", id: "poll-\(i)", status: "completed", name: "wait", readOnly: true) }
        try fixture.append("one", type: "event_msg", payload: context(used: 900, capacity: 1000, total: 900))
        try fixture.append("one", type: "event_msg", payload: context(used: 910, capacity: 1000, total: 1810))
        let high = await engine.poll(selectedID: "one")
        try expectFalse(high.attention.contains { $0.rule == "repeat" && !$0.resolved })
        try expectTrue(high.attention.contains { $0.rule == "context" && !$0.resolved })
        try fixture.append("one", type: "event_msg", payload: context(used: 200, capacity: 1000, total: 2010))
        let low = await engine.poll(selectedID: "one")
        try expectTrue(low.attention.contains { $0.rule == "context" && $0.resolved })
    }

    func testNewResponsesBelongToOriginThreadAndForkReplayDoesNotDoubleCount() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("root", log: true); try fixture.add("fork", log: true)
        let engine = fixture.engine(); _ = await engine.poll()
        try fixture.append("root", type: "token_usage_record", payload: usage("root", "response"))
        try fixture.append("fork", type: "token_usage_record", payload: usage("root", "response"))
        _ = await engine.poll(selectedID: "root")
        let result = await engine.poll(selectedID: "fork")
        try expectEqual(result.observedTokens, 120)
        let fork = await engine.observation("fork")
        try expectTrue(fork.usage.isEmpty)
    }

    func testPaginationUsesCursorAndDoesNotResumeThread() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one")
        try fixture.history.execute("BEGIN")
        for i in 0..<205 {
            let item: [String: Any] = ["type": "commandExecution", "id": "i-\(i)", "command": "echo sample", "status": "completed", "durationMs": 1000]
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: item), as: UTF8.self)
            try fixture.history.execute("INSERT INTO thread_items VALUES(?,?,?,?,?,?)",
                ["one", "t", "i-\(i)", String(i), String(Date().timeIntervalSince1970 * 1000), raw])
        }
        try fixture.history.execute("COMMIT")
        let engine = fixture.engine()
        let a = await engine.timeline("one")
        let b = await engine.timeline("one", before: a.before)
        let c = await engine.timeline("one", before: b.before)
        try expectEqual(a.events.count, 100); try expectEqual(b.events.count, 100); try expectEqual(c.events.count, 5)
        try expectFalse(c.hasMore)
        try expectTrue(Set(a.events.map(\.id)).isDisjoint(with: b.events.map(\.id)))
        let detail = await engine.detail(a.events[0].source)
        try expectTrue(detail.contains("echo sample"))
    }

    func testMissingDatabaseKeepsPreviousSnapshotAndReportsFailure() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        try fixture.append("one", type: "event_msg", payload: ["type": "task_started", "turn_id": "t"])
        let engine = fixture.engine(); _ = await engine.poll(selectedID: "one")
        try FileManager.default.moveItem(at: fixture.home.appendingPathComponent("state_5.sqlite"), to: fixture.home.appendingPathComponent("temporarily-unavailable"))
        let result = await engine.poll()
        try expectEqual(result.sessions.count, 1)
        try expectEqual(result.sessions.first?.state, .running)
        try expectFalse(result.diagnostics.isEmpty)
    }

    func testFiveThousandSessionCatalogAndTwentyUpdatingSessions() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.state.execute("BEGIN")
        for i in 0..<5000 { try fixture.add("session-\(i)", log: i < 20) }
        try fixture.state.execute("COMMIT")
        let engine = fixture.engine()
        let began = Date(); let initial = await engine.poll()
        try expectEqual(initial.sessions.count, 5000)
        try expectLessThan(Date().timeIntervalSince(began), 5)
        for i in 0..<20 {
            try fixture.append("session-\(i)", type: "event_msg", payload: ["type": "task_started", "turn_id": "t"])
            try fixture.tool("session-\(i)", id: "tool-\(i)", status: "completed")
        }
        var last = initial
        for _ in 0..<3 { last = await engine.poll(now: Date().addingTimeInterval(1)) }
        try expectEqual(last.sessions.filter { $0.state == .running }.count, 20)
        print("PERFORMANCE catalog_ms=\(Int(Date().timeIntervalSince(began) * 1000)) last_poll_ms=\(Int(last.durationMs))")
    }

    func testHistoryOutageRetainsStatusAndNewerCompletionWins() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        let began = Date().timeIntervalSince1970
        try fixture.append("one", type: "event_msg", payload: ["type": "task_started", "turn_id": "t"])
        try fixture.history.execute("INSERT INTO thread_turns VALUES('one','t',1,'completed',?,?,NULL)",
                                    [String(began - 10), String(began + 10)])
        let engine = fixture.engine()
        let completed = await engine.poll(selectedID: "one")
        try expectEqual(completed.sessions.first?.state, .completed)
        try fixture.history.execute("ALTER TABLE thread_turns RENAME TO unavailable_turns")
        let stale = await engine.poll(selectedID: "one")
        try expectEqual(stale.sessions.first?.state, .completed)
        try expectTrue(stale.diagnostics.contains { $0.contains("保留上次状态") })
    }

    func testFileReplacementAndEvidenceValidation() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("one", log: true)
        try fixture.tool("one", id: "original", status: "completed")
        let engine = fixture.engine()
        _ = await engine.poll(selectedID: "one")
        let old = await engine.observation("one")
        let event = try requireValue(old.events.last)
        // Replace with a new inode and different, valid records.
        try Data().write(to: fixture.log("one"), options: .atomic)
        try fixture.append("one", type: "session_meta", payload: ["id": "one"])
        try fixture.append("one", type: "event_msg", payload: ["type": "task_started", "turn_id": "replacement"])
        _ = await engine.poll(selectedID: "one")
        let fresh = await engine.observation("one")
        try expectFalse(fresh.events.contains { $0.id == event.id })
        let detail = await engine.detail(event.source)
        try expectTrue(detail.contains("源记录已变化"))
    }

    func testColdSessionReconciliationAndTruncatedLogRecovery() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.add("cold", log: true)
        try fixture.state.execute("UPDATE threads SET updated_at_ms=1 WHERE id='cold'")
        let engine = fixture.engine()
        _ = await engine.poll() // Establish a baseline without loading cold history.
        try fixture.append("cold", type: "event_msg", payload: ["type": "task_started", "turn_id": "t"])
        var snapshot = await engine.poll()
        for _ in 0..<15 { snapshot = await engine.poll() }
        try expectEqual(snapshot.sessions.first?.state, .running)
        let handle = try FileHandle(forWritingTo: fixture.log("cold"))
        try handle.truncate(atOffset: 0); try handle.close()
        try fixture.append("cold", type: "session_meta", payload: ["id": "cold"])
        _ = await engine.poll(selectedID: "cold")
        let cleared = await engine.observation("cold")
        try expectTrue(cleared.events.isEmpty)
        try expectTrue(cleared.note?.contains("截断") == true)
    }

    private func usage(_ thread: String, _ response: String) -> [String: Any] {
        let tokens: [String: Any] = ["input_tokens": 100, "cached_input_tokens": 50, "output_tokens": 20, "reasoning_output_tokens": 10, "total_tokens": 120]
        return ["response_id": response, "thread_id": thread, "turn_id": "t", "usage": tokens, "thread_token_usage": tokens, "turn_token_usage": tokens]
    }
    private func context(used: Int, capacity: Int, total: Int) -> [String: Any] {
        ["type": "token_count", "info": ["model_context_window": capacity,
            "last_token_usage": ["total_tokens": used, "input_tokens": used],
            "total_token_usage": ["total_tokens": total, "input_tokens": total]]]
    }
}

private struct Fixture {
    let root: URL
    let home: URL
    let state: FixtureConnection
    let history: FixtureConnection
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-tests-\(UUID().uuidString)")
        home = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        state = try FixtureConnection(home.appendingPathComponent("state_5.sqlite").path, readOnly: false)
        history = try FixtureConnection(home.appendingPathComponent("thread_history_1.sqlite").path, readOnly: false)
        try state.execute("CREATE TABLE threads(id TEXT PRIMARY KEY,name TEXT,cwd TEXT,model TEXT,reasoning_effort TEXT,source TEXT,rollout_path TEXT,archived INTEGER,updated_at_ms INTEGER)")
        try state.execute("CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT,status TEXT)")
        try history.execute("CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,status TEXT,started_at INTEGER,completed_at INTEGER,error_json TEXT)")
        try history.execute("CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_json TEXT)")
        try history.execute("CREATE INDEX thread_items_page ON thread_items(thread_id,rollout_ordinal)")
    }
    func engine() -> MonitorEngine { MonitorEngine(home: home, cacheDirectory: root.appendingPathComponent("cache")) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func log(_ id: String) -> URL { home.appendingPathComponent("\(id).jsonl") }
    func add(_ id: String, workspace: String = "/work/project", model: String = "sample-model", archived: Bool = false, log exists: Bool = false) throws {
        try state.execute("INSERT INTO threads VALUES(?,?,?,?,?,?,?, ?,?)",
            [id, "Task \(id)", workspace, model, "high", "cli", exists ? log(id).path : "", archived ? "1" : "0", String(Int64(Date().timeIntervalSince1970 * 1000))])
        if exists {
            FileManager.default.createFile(atPath: log(id).path, contents: nil)
            try append(id, type: "session_meta", payload: ["id": id])
        }
    }
    func write(_ id: String, data: Data) throws {
        let handle = try FileHandle(forWritingTo: log(id)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    func append(_ id: String, type: String, payload: [String: Any]) throws {
        let record: [String: Any] = ["type": type, "timestamp": Date().timeIntervalSince1970 + 0.001, "payload": payload]
        try write(id, data: JSONSerialization.data(withJSONObject: record) + Data([10]))
    }
    func tool(_ id: String, id itemID: String, status: String, name: String = "sample_tool", readOnly: Bool = false) throws {
        try append(id, type: "event_msg", payload: ["type": "item_completed", "turn_id": "t",
            "item": ["type": "McpToolCall", "id": itemID, "tool": name, "arguments": ["query": "sample"],
                     "status": status, "result": ["text": "same result"], "readOnlyHint": readOnly]])
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) throws {
    guard a == b else { throw CheckFailure(description: "\(file):\(line): equality check failed") }
}
private func expectNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) throws {
    guard a != b else { throw CheckFailure(description: "\(file):\(line): inequality check failed") }
}
private func expectTrue(_ value: Bool, file: StaticString = #fileID, line: UInt = #line) throws {
    guard value else { throw CheckFailure(description: "\(file):\(line): expected true") }
}
private func expectFalse(_ value: Bool, file: StaticString = #fileID, line: UInt = #line) throws {
    try expectTrue(!value, file: file, line: line)
}
private func expectLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) throws {
    guard a < b else { throw CheckFailure(description: "\(file):\(line): upper bound exceeded") }
}
private func requireValue<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw CheckFailure(description: "\(file):\(line): missing value") }
    return value
}

@main
struct ObservationChecksMain {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL \(error)"); exit(1) }
    }
    @MainActor private static func run() async throws {
        let tests = ObservationTests()
        try await tests.testLocalizationCatalogAndSourceArguments()
        print("PASS testLocalizationCatalogAndSourceArguments")
        try await tests.testLocalizedCachedEvidencePreservesSourceText()
        print("PASS testLocalizedCachedEvidencePreservesSourceText")
        try await tests.testLocalizedMaterialAndDetailPagination()
        print("PASS testLocalizedMaterialAndDetailPagination")
        try await tests.testLegacyCheckpointRebuildKeepsUsageAndSeenMarkers()
        print("PASS testLegacyCheckpointRebuildKeepsUsageAndSeenMarkers")
        try await tests.testSessionOrderingUsesExecutionTimeAndStableTies()
        print("PASS testSessionOrderingUsesExecutionTimeAndStableTies")
        try await tests.testSessionOrderingIncludesDescendantsAndGuardsCycles()
        print("PASS testSessionOrderingIncludesDescendantsAndGuardsCycles")
        try await tests.testOldInProgressIsNotLiveDespiteRecentCatalogEdits()
        print("PASS testOldInProgressIsNotLiveDespiteRecentCatalogEdits")
        try await tests.testActivityExpiresAndRecoversWithoutInventingCompletion()
        print("PASS testActivityExpiresAndRecoversWithoutInventingCompletion")
        try await tests.testCatalogCoversArchiveSystemChildrenAndDuplicateWorkspaceNames()
        print("PASS testCatalogCoversArchiveSystemChildrenAndDuplicateWorkspaceNames")
        try await tests.testIncrementalUsageDedupAndRestart()
        print("PASS testIncrementalUsageDedupAndRestart")
        try await tests.testPartialLineIsNotConsumedUntilNewline()
        print("PASS testPartialLineIsNotConsumedUntilNewline")
        try await tests.testContextSamplesRemainSeparateFromCumulativeUsageAndCompaction()
        print("PASS testContextSamplesRemainSeparateFromCumulativeUsageAndCompaction")
        try await tests.testWaitingResolutionAndToolFailureDoNotInventTurnFailure()
        print("PASS testWaitingResolutionAndToolFailureDoNotInventTurnFailure")
        try await tests.testRulesMergeEvidenceExcludePollingAndResolveContextPressure()
        print("PASS testRulesMergeEvidenceExcludePollingAndResolveContextPressure")
        try await tests.testNewResponsesBelongToOriginThreadAndForkReplayDoesNotDoubleCount()
        print("PASS testNewResponsesBelongToOriginThreadAndForkReplayDoesNotDoubleCount")
        try await tests.testPaginationUsesCursorAndDoesNotResumeThread()
        print("PASS testPaginationUsesCursorAndDoesNotResumeThread")
        try await tests.testMissingDatabaseKeepsPreviousSnapshotAndReportsFailure()
        print("PASS testMissingDatabaseKeepsPreviousSnapshotAndReportsFailure")
        try await tests.testFiveThousandSessionCatalogAndTwentyUpdatingSessions()
        print("PASS testFiveThousandSessionCatalogAndTwentyUpdatingSessions")
        try await tests.testHistoryOutageRetainsStatusAndNewerCompletionWins()
        print("PASS testHistoryOutageRetainsStatusAndNewerCompletionWins")
        try await tests.testFileReplacementAndEvidenceValidation()
        print("PASS testFileReplacementAndEvidenceValidation")
        try await tests.testColdSessionReconciliationAndTruncatedLogRecovery()
        print("PASS testColdSessionReconciliationAndTruncatedLogRecovery")
        try await tests.testCatalogBoundsEmbeddedPromptMetadata()
        print("PASS testCatalogBoundsEmbeddedPromptMetadata")
        try await tests.testColdCheckpointResumesWithoutSelectionAfterRestart()
        print("PASS testColdCheckpointResumesWithoutSelectionAfterRestart")
        try await tests.testContextReplacementPreservesOnlyRecordedMaterialsAndOpaqueSummary()
        print("PASS testContextReplacementPreservesOnlyRecordedMaterialsAndOpaqueSummary")
        try await tests.testContextCategoriesToolResultsAndCheckpointCutoff()
        print("PASS testContextCategoriesToolResultsAndCheckpointCutoff")
        try await tests.testContextIncrementalIndexAndMissingReplacementRemainExplicit()
        print("PASS testContextIncrementalIndexAndMissingReplacementRemainExplicit")
        try await tests.testContextComparisonUsesAdjacentPositionsAndRespectsModelAndPhaseBoundaries()
        print("PASS testContextComparisonUsesAdjacentPositionsAndRespectsModelAndPhaseBoundaries")
        print("Observation checks passed: 27 scenarios")
    }
}
