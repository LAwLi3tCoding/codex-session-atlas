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
    @Published var usesRuntimeTitles = false

    private let store = SQLiteAgentStore()
    private let titleSource = CodexAppServerTitleSource()
    private var runtimeTitles: [String: String] = [:]
    private let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite")

    init() { refresh() }

    func refresh() {
        snapshot = store.load(at: databaseURL, runtimeTitles: runtimeTitles)
        titleSource.refresh { [weak self] titles in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.runtimeTitles = titles
                self.usesRuntimeTitles = !titles.isEmpty
                self.snapshot = self.store.load(at: self.databaseURL, runtimeTitles: titles)
            }
        }
    }
}

private final class CodexAppServerTitleSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codex-agent-monitor.app-server")
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var initialized = false
    private var requestState = AppServerRequestState()
    private var timeoutWorkItem: DispatchWorkItem?
    private var initializeRequestID: Int?
    private var refreshPending = false
    private var completion: (@Sendable ([String: String]) -> Void)?

    func refresh(completion: @escaping @Sendable ([String: String]) -> Void) {
        queue.async {
            self.completion = completion
            self.refreshPending = true
            self.startIfNeeded()
            self.requestTitlesIfReady()
        }
    }

    deinit {
        timeoutWorkItem?.cancel()
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
    }

    private func startIfNeeded() {
        guard process?.isRunning != true, let executable = executableURL() else {
            if process?.isRunning != true { finish(with: [:]) }
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [
            "app-server", "--listen", "stdio://",
            "--disable", "plugins", "--disable", "remote_plugin", "--disable", "apps",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.queue.async { self.consume(data) }
        }
        let processIdentifier = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.process.map({ ObjectIdentifier($0) }) == processIdentifier else { return }
                self.failCurrentProcess(terminate: false)
            }
        }

        do {
            self.process = process
            self.input = input
            self.output = output
            try process.run()
            guard let requestID = requestState.startNext() else {
                failCurrentProcess()
                return
            }
            initializeRequestID = requestID
            armTimeout(for: requestID)
            send([
                "id": requestID,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-agent-desktop-monitor",
                        "title": "Codex Agent Monitor",
                        "version": "0.1.0",
                    ],
                    "capabilities": ["experimentalApi": true],
                ],
            ])
        } catch {
            failCurrentProcess(terminate: false)
        }
    }

    private func requestTitlesIfReady() {
        guard initialized, refreshPending, requestState.requestID == nil else { return }
        refreshPending = false
        guard let requestID = requestState.startNext() else { return }
        armTimeout(for: requestID)
        send([
            "id": requestID,
            "method": "thread/list",
            "params": [
                "archived": false,
                "limit": 200,
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "useStateDbOnly": false,
                "sourceKinds": [
                    "cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
                    "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown",
                ],
            ],
        ])
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let id = object["id"] as? Int
            else { continue }

            if id == initializeRequestID {
                guard requestState.finish(id) else { continue }
                initializeRequestID = nil
                cancelTimeout()
                guard object["result"] != nil else {
                    failCurrentProcess()
                    continue
                }
                initialized = true
                send(["method": "initialized"])
                requestTitlesIfReady()
                continue
            }

            guard requestState.finish(id) else { continue }
            cancelTimeout()
            refreshPending = false
            let threads = (object["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            var titles: [String: String] = [:]
            for thread in threads {
                guard let id = thread["id"] as? String else { continue }
                titles[id] = CodexRuntimeTitle.resolve(
                    threadID: id,
                    name: thread["name"] as? String,
                    preview: thread["preview"] as? String
                )
            }
            finish(with: titles)
        }
    }

    private func armTimeout(for requestID: Int) {
        cancelTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.requestState.expire(requestID) else { return }
            self.timeoutWorkItem = nil
            self.failCurrentProcess()
        }
        timeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    private func failCurrentProcess(terminate: Bool = true) {
        cancelTimeout()
        requestState.reset()
        initializeRequestID = nil
        initialized = false
        refreshPending = false
        buffer.removeAll(keepingCapacity: true)
        output?.fileHandleForReading.readabilityHandler = nil
        let process = process
        self.process = nil
        input = nil
        output = nil
        finish(with: [:])
        if terminate, process?.isRunning == true { process?.terminate() }
    }

    private func finish(with titles: [String: String]) {
        let completion = completion
        self.completion = nil
        completion?(titles)
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        try? input?.fileHandleForWriting.write(contentsOf: data)
    }

    private func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map(URL.init(fileURLWithPath:))
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
    static let elevated = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.17, alpha: 1)
            : NSColor.white
    })
}

@MainActor
private struct ContentView: View {
    @ObservedObject var monitor: MonitorModel
    @State private var selectedSessionID: String?
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(snapshot: monitor.snapshot) { monitor.refresh() }
            Divider()

            if monitor.snapshot.roots.isEmpty {
                EmptyState(message: monitor.snapshot.diagnostics.first ?? "Codex may be offline.")
            } else {
                GeometryReader { geometry in
                    responsiveContent(
                        mode: MonitorPanelLayout.mode(forWidth: Double(geometry.size.width))
                    )
                }
            }

            Divider()
            HStack(spacing: 7) {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
                Text(monitor.usesRuntimeTitles
                    ? "Codex app-server titles · SQLite runtime metadata · refreshes every 5s"
                    : "SQLite fallback · observed/inferred activity · refreshes every 5s")
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

    @ViewBuilder
    private func responsiveContent(mode: MonitorPanelMode) -> some View {
        switch mode {
        case .compact:
            SessionGrid(workspaces: monitor.snapshot.workspaces, compact: true)
        case .overview:
            HStack(spacing: 0) {
                WorkspaceSidebar(workspaces: monitor.snapshot.workspaces)
                Divider()
                SessionGrid(workspaces: monitor.snapshot.workspaces, compact: false)
            }
        case .inspector:
            HStack(spacing: 0) {
                WorkspaceSidebar(workspaces: monitor.snapshot.workspaces)
                Divider()
                SessionRail(
                    workspaces: monitor.snapshot.workspaces,
                    selectedID: effectiveSelectedSession?.id,
                    select: { selectedSessionID = $0 }
                )
                Divider()
                SessionInspector(session: effectiveSelectedSession)
            }
        }
    }

    private var allSessions: [AgentNode] {
        monitor.snapshot.workspaces.flatMap(\.sessions)
    }

    private var effectiveSelectedSession: AgentNode? {
        let resolvedID = MonitorPanelLayout.resolvedSelection(
            preferredID: selectedSessionID,
            availableIDs: allSessions.map(\.id)
        )
        return allSessions.first { $0.id == resolvedID }
    }
}

@MainActor
private struct AppHeader: View {
    let snapshot: AgentSnapshot
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.elevated)
                    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Sessions")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
            }
            .foregroundStyle(Theme.green)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Theme.green.opacity(0.09), in: Capsule())

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
        .padding(.horizontal, 18)
        .frame(height: 64)
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
private struct SessionGrid: View {
    let workspaces: [WorkspaceGroup]
    let compact: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(workspaces) { workspace in
                    WorkspaceSection(workspace: workspace, compact: compact)
                }
            }
            .padding(compact ? 14 : 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

@MainActor
private struct WorkspaceSection: View {
    let workspace: WorkspaceGroup
    let compact: Bool

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

            LazyVGrid(
                columns: compact
                    ? [GridItem(.flexible())]
                    : [GridItem(.adaptive(minimum: 330, maximum: 520), spacing: 16, alignment: .top)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(workspace.sessions) { session in
                    SessionCard(session: session)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

@MainActor
private struct SessionRail: View {
    let workspaces: [WorkspaceGroup]
    let selectedID: String?
    let select: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RUNNING NOW")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(Theme.coral)
                    Text("Select a session to inspect its delegation tree.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                ForEach(workspaces) { workspace in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(workspace.name)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            Spacer()
                            Text("\(workspace.sessions.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        ForEach(workspace.sessions) { session in
                            Button { select(session.id) } label: {
                                SessionRailCard(session: session, selected: selectedID == session.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Inspect \(session.name)")
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 356)
        .background(Theme.canvas)
    }
}

@MainActor
private struct SessionRailCard: View {
    let session: AgentNode
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(selected ? Theme.coral : (session.isActive ? Theme.green : Theme.orange))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.currentActivity ?? session.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Circle()
                        .fill(session.isActive ? Theme.green : Theme.orange)
                        .frame(width: 7, height: 7)
                }

                HStack(spacing: 7) {
                    Text(session.model)
                    Text("·")
                    Text(session.reasoningEffort)
                    Spacer(minLength: 4)
                    Label("\(descendants(of: session))", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(
            selected ? Theme.elevated : Theme.elevated.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Theme.coral.opacity(0.42) : Color.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: selected ? Theme.coral.opacity(0.08) : .clear, radius: 10, y: 4)
    }
}

@MainActor
private struct SessionInspector: View {
    let session: AgentNode?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.sea.opacity(0.045), Theme.canvas, Theme.coral.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("SESSION INSPECTOR")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .tracking(1.5)
                                    .foregroundStyle(Theme.sea)
                                Text(session.currentActivity ?? session.name)
                                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                                    .lineLimit(3)
                                Text("\(session.workspaceName) · \(shortSessionID(session.id))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 16)
                            StatusPill(isActive: session.isActive)
                        }

                        HStack(spacing: 10) {
                            InspectorMetric(
                                label: "AGENTS",
                                value: "\(descendants(of: session) + 1)",
                                symbol: "point.3.connected.trianglepath.dotted",
                                tint: Theme.sea
                            )
                            InspectorMetric(
                                label: "ACTIVE NOW",
                                value: "\(activeAgentCount(session))",
                                symbol: "waveform.path.ecg",
                                tint: Theme.green
                            )
                            InspectorMetric(
                                label: "TOKENS",
                                value: tokenSummary(session),
                                symbol: "sum",
                                tint: Theme.coral
                            )
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("LIVE AGENT TREE")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .tracking(1.4)
                                .foregroundStyle(.tertiary)
                            AgentTreeDetail(session: session)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct InspectorMetric: View {
    let label: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(Theme.elevated.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

@MainActor
private struct AgentTreeDetail: View {
    let session: AgentNode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(session.isActive ? Theme.green : Theme.orange)
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MAIN AGENT")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(Theme.coral)
                    Text(session.name)
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                StatusPill(isActive: session.isActive, compact: true)
            }

            AgentActivityLine(
                activity: session.currentActivity ?? (session.isActive ? "Task details unavailable" : "Context retained for active child"),
                unavailable: session.currentActivity == nil
            )
            RuntimeLine(agent: session)

            if !session.children.isEmpty {
                Divider()
                ForEach(session.children) { SubagentRow(agent: $0, depth: 0) }
            }
        }
        .padding(16)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.045), radius: 12, y: 4)
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
                    Text(session.currentActivity ?? session.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    Text(shortSessionID(session.id))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
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

private func activeAgentCount(_ agent: AgentNode) -> Int {
    (agent.isActive ? 1 : 0) + agent.children.reduce(0) { $0 + activeAgentCount($1) }
}

private func tokenSummary(_ agent: AgentNode) -> String {
    let total = (agent.tokensUsed ?? 0) + agent.children.reduce(0) { $0 + tokenTotal($1) }
    return total == 0 ? "—" : total.formatted(.number.notation(.compactName))
}

private func tokenTotal(_ agent: AgentNode) -> Int {
    (agent.tokensUsed ?? 0) + agent.children.reduce(0) { $0 + tokenTotal($1) }
}

private func shortSessionID(_ id: String) -> String {
    id.count > 12 ? "\(id.prefix(8))…\(id.suffix(4))" : id
}
