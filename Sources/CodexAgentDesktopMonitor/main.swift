import AppKit
import CodexAgentMonitor
import Combine
import SwiftUI

@main
struct CodexAgentDesktopMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        let monitor = MonitorModel()
        let content = ContentView(monitor: monitor)
        let window = NSWindow(
            contentRect: NSRect(x: 160, y: 180, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Agent Monitor"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.contentView = NSHostingView(rootView: content)
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("CodexAgentDesktopMonitor.Panel")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var snapshot = AgentSnapshot(roots: [], diagnostics: [])

    private let store = SQLiteAgentStore()
    private let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite")

    init() { refresh() }

    func refresh() {
        snapshot = store.load(at: databaseURL)
    }
}

private enum Theme {
    static let ink = Color.primary
    static let sea = Color(red: 0.16, green: 0.61, blue: 0.56)
    static let coral = Color(red: 0.89, green: 0.37, blue: 0.27)
    static let green = Color(red: 0.20, green: 0.69, blue: 0.42)
    static let orange = Color(red: 0.91, green: 0.51, blue: 0.30)
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.105, alpha: 1)
            : NSColor(calibratedWhite: 0.975, alpha: 1)
    })
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.14, alpha: 1)
            : NSColor(calibratedRed: 0.93, green: 0.945, blue: 0.945, alpha: 1)
    })
    static let card = Color(nsColor: .controlBackgroundColor)
}

@MainActor
private struct ContentView: View {
    @ObservedObject var monitor: MonitorModel
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(snapshot: monitor.snapshot) { monitor.refresh() }
            Divider()

            if monitor.snapshot.roots.isEmpty {
                EmptyState(message: monitor.snapshot.diagnostics.first ?? "Codex may be offline.")
            } else {
                HStack(spacing: 0) {
                    WorkspaceSidebar(workspaces: monitor.snapshot.workspaces)
                    Divider()
                    SessionList(workspaces: monitor.snapshot.workspaces)
                }
            }

            Divider()
            HStack(spacing: 7) {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
                Text("SQLite read-only · observed/inferred activity · refreshes every 5s")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(.bar)
        }
        .background(Theme.canvas)
        .frame(minWidth: 560, minHeight: 420)
        .onReceive(refreshTimer) { _ in monitor.refresh() }
    }
}

@MainActor
private struct AppHeader: View {
    let snapshot: AgentSnapshot
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Sessions")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            .accessibilityLabel("Refresh sessions")
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(.bar)
    }

    private var summary: String {
        let active = snapshot.roots.filter(\.isActive).count
        let delegated = snapshot.roots.count - active
        return "\(active) observed active\(delegated == 0 ? "" : " · \(delegated) delegating")"
    }
}

@MainActor
private struct WorkspaceSidebar: View {
    let workspaces: [WorkspaceGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarLabel("Workspaces")
                .padding(.top, 20)
                .padding(.bottom, 8)

            ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                WorkspaceSidebarRow(
                    workspace: workspace,
                    accent: index.isMultiple(of: 2) ? Theme.coral : Theme.sea
                )
            }

            Divider().padding(.vertical, 18)
            SidebarLabel("Status")
                .padding(.bottom, 10)
            StatusSummary(color: Theme.green, label: "Observed active", value: workspaces.flatMap(\.sessions).filter(\.isActive).count)
            StatusSummary(color: Theme.orange, label: "Active child", value: workspaces.flatMap(\.sessions).filter { !$0.isActive }.count)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 176)
        .background(Theme.sidebar)
    }
}

@MainActor
private struct SidebarLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.3)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
    }
}

@MainActor
private struct WorkspaceSidebarRow: View {
    let workspace: WorkspaceGroup
    let accent: Color

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(accent)
                .frame(width: 19, height: 19)
                .overlay {
                    Image(systemName: "square.stack.3d.down.right.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.94))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(workspace.sessions.count) session\(workspace.sessions.count == 1 ? "" : "s") · \(descendantCount(in: workspace)) agents")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor
private struct StatusSummary: View {
    let color: Color
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11))
            Spacer()
            Text("\(value)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }
}

@MainActor
private struct SessionList: View {
    let workspaces: [WorkspaceGroup]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(workspaces) { workspace in
                    WorkspaceSection(workspace: workspace)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

@MainActor
private struct WorkspaceSection: View {
    let workspace: WorkspaceGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Text("\(workspace.sessions.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.055), in: Capsule())
                Spacer()
            }

            ForEach(workspace.sessions) { SessionCard(session: $0) }
        }
    }
}

@MainActor
private struct SessionCard: View {
    let session: AgentNode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(session.isActive ? Theme.green : Theme.orange)
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(sessionHeaderLabel)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(Theme.coral)
                    Text(session.currentActivity ?? sessionTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    if session.name != "Main session" {
                        Text(shortSessionID(session.id))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 8)
                StatusPill(isActive: session.isActive)
            }

            RuntimeLine(agent: session)

            if !session.children.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.children) { SubagentRow(agent: $0, depth: 0) }
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.045), radius: 9, y: 3)
    }

    private var sessionTitle: String {
        session.name == "Main session" ? "Session \(shortSessionID(session.id))" : session.name
    }

    private var sessionHeaderLabel: String {
        if !session.isActive { return "MAIN AGENT · ACTIVE CHILD" }
        return session.currentActivity == nil ? "MAIN AGENT · TASK UNAVAILABLE" : "MAIN AGENT · DOING"
    }
}

@MainActor
private struct SubagentRow: View {
    let agent: AgentNode
    let depth: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Rectangle().fill(Color.primary.opacity(0.13)).frame(width: 1, height: 12)
                Circle().fill(agent.isActive ? Theme.sea : Theme.orange).frame(width: 8, height: 8)
                Rectangle().fill(Color.primary.opacity(0.13)).frame(width: 1, height: 28)
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(shortSessionID(agent.id))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 6)
                    StatusPill(isActive: agent.isActive, compact: true)
                }
                AgentActivityLine(
                    activity: agent.currentActivity ?? (agent.isActive ? "Task details unavailable" : "Context retained for active child"),
                    unavailable: agent.currentActivity == nil
                )
                RuntimeLine(agent: agent, compact: true)
                ForEach(agent.children) { SubagentRow(agent: $0, depth: depth + 1) }
            }
            .padding(.top, 5)
        }
        .padding(.leading, CGFloat(depth) * 12)
    }
}

@MainActor
private struct AgentActivityLine: View {
    let activity: String
    var unavailable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(unavailable ? "TASK" : "DOING")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(unavailable ? Color.secondary : Theme.sea)
            Text(activity)
                .font(.system(size: 11))
                .foregroundStyle(unavailable ? .tertiary : .secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(unavailable ? activity : "Doing \(activity)")
    }
}

@MainActor
private struct RuntimeLine: View {
    let agent: AgentNode
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RuntimeTag(agent.model, tint: Theme.ink)
                RuntimeTag(agent.reasoningEffort, tint: Theme.sea)
                if let role = agent.role, !role.isEmpty { RuntimeTag(role, tint: Theme.coral) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                if let tokens = agent.tokensUsed { Label("\(tokens.formatted()) tok", systemImage: "sum") }
                if let updatedAt = agent.updatedAt {
                    Label { Text(updatedAt, style: .relative) } icon: { Image(systemName: "clock") }
                }
                if compact { Spacer(minLength: 0) }
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct RuntimeTag: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.09), in: Capsule())
    }
}

@MainActor
private struct StatusPill: View {
    let isActive: Bool
    var compact = false

    var body: some View {
        let color = isActive ? Theme.green : Theme.orange
        Text(isActive ? (compact ? "ACTIVE" : "OBSERVED ACTIVE") : (compact ? "CONTEXT" : "ACTIVE CHILD"))
            .font(.system(size: compact ? 8 : 9, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .background(color.opacity(0.10), in: Capsule())
    }
}

@MainActor
private struct EmptyState: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.sea.opacity(0.09))
                    .frame(width: 66, height: 66)
                Image(systemName: "square.stack.3d.down.right")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(Theme.sea)
            }
            Text("No active sessions")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

private func descendantCount(in workspace: WorkspaceGroup) -> Int {
    workspace.sessions.reduce(0) { $0 + descendants(of: $1) }
}

private func descendants(of agent: AgentNode) -> Int {
    agent.children.reduce(agent.children.count) { $0 + descendants(of: $1) }
}

private func shortSessionID(_ id: String) -> String {
    id.count > 12 ? "\(id.prefix(8))…\(id.suffix(4))" : id
}
