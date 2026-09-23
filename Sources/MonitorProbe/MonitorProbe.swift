import SessionAtlasCore
import Foundation

// Read-only live acceptance probe. Prints counts and timings, never session content.
@main
struct MonitorProbe {
    static func main() async {
        let args = CommandLine.arguments
        let home = URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
        let cache = URL(fileURLWithPath: args.count > 2 ? args[2] : FileManager.default.temporaryDirectory.appendingPathComponent("codex-monitor-probe").path)
        let engine = MonitorEngine(home: home, cacheDirectory: cache)
        await engine.start()
        var snapshot = await engine.poll()
        for _ in 0..<2 { snapshot = await engine.poll(selectedID: snapshot.sessions.first?.id) }
        let first = args.count > 3 ? snapshot.sessions.first { $0.id == args[3] } : snapshot.sessions.first
        let observation = first == nil ? SessionObservation() : await engine.observation(first!.id)
        let timeline = first == nil ? nil : await engine.timeline(first!.id)
        var history = ContextHistory()
        let began = Date()
        if let first, let path = first.rolloutPath {
            let explorer = ContextExplorer()
            history = await explorer.load(threadID: first.id, path: path)
            for _ in 0..<31 where !history.complete && history.note == nil {
                history = await explorer.load(threadID: first.id, path: path)
            }
        }
        let report: [String: Any] = [
            "sessions": snapshot.sessions.count, "initialized": snapshot.initializedCount,
            "recently_active": snapshot.sessions.filter(\.isRecentlyActive).count,
            "unconfirmed": snapshot.sessions.filter { $0.state == .unconfirmed }.count,
            "waiting": snapshot.sessions.filter { $0.state == .waiting }.count,
            "children": snapshot.sessions.filter { $0.parentID != nil }.count,
            "archived": snapshot.sessions.filter(\.archived).count,
            "context_samples": observation.contexts.count, "usage_samples": observation.usage.count,
            "trace_events": observation.events.count, "last_poll_ms": Int(snapshot.durationMs),
            "diagnostic_count": snapshot.diagnostics.count,
            "diagnostics": snapshot.diagnostics,
            "timeline_events": timeline?.events.count ?? 0,
            "timeline_note": timeline?.note ?? "none",
            "composition_ms": Int(Date().timeIntervalSince(began) * 1000),
            "composition_phases": history.phases.count,
            "composition_complete": history.complete,
            "composition_materials": history.phases.last?.materials.count ?? 0,
            "composition_categories": Dictionary(grouping: history.phases.last?.materials ?? [], by: { $0.category.rawValue }).mapValues(\.count),
            "composition_opaque": history.phases.last?.materials.filter { !$0.readable }.count ?? 0,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        await engine.stop()
    }
}
