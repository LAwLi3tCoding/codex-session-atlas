import AppKit
import SessionAtlasCore
import SwiftUI
import UserNotifications

@main
struct CodexSessionAtlasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { MonitorSettings(model: delegate.model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MonitorModel()
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { NSApp.applicationIconImage = NSImage(contentsOf: url) }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex Session Atlas"
        window.contentMinSize = NSSize(width: 720, height: 540)
        window.contentView = NSHostingView(rootView: MonitorWorkspace(model: model))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("CodexAgentDesktopMonitor.Panel")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        model.start()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); sender.activate(ignoringOtherApps: true); return true
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var snapshot = ObservationSnapshot()
    @Published var selectedID: String?
    @Published var observation = SessionObservation()
    @Published var events: [TraceEvent] = []
    @Published var pageNote: String?
    @Published var hasMore = false
    @Published var loadingHistory = false
    @Published var detailText = ""
    @Published var detailEvent: TraceEvent?
    @Published var detailMaterial: ContextMaterial?
    @Published var rawDetail = false
    @Published var contextHistory = ContextHistory()
    @Published var contextLoading = false
    @Published var detailTab = "概览"
    @Published var notifications = UserDefaults.standard.bool(forKey: "notifications")
    @Published var rules = RuleSettings()
    @Published var showSettings = false
    private var engine: MonitorEngine
    private let contextExplorer = ContextExplorer()
    private var task: Task<Void, Never>?
    private var cursor: Int64?
    private var pageCount = 1
    private var notificationIDs = Set<String>()
    private let launchedAt = Date()
    private var detailOffset = 0
    private var titleSource = CodexAppServerTitleSource()
    private var runtimeTitles: [String: String] = [:]
    private var titleRequested = false
    let home: URL

    init() {
        home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
                   ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
        let support = ProcessInfo.processInfo.environment["CODEX_MONITOR_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexAgentMonitor")
        engine = MonitorEngine(home: home, cacheDirectory: support)
        if let data = UserDefaults.standard.data(forKey: "rules"), let saved = try? JSONDecoder().decode(RuleSettings.self, from: data) { rules = saved }
    }
    var selected: SessionSummary? { snapshot.sessions.first { $0.id == selectedID } }
    func title(_ session: SessionSummary) -> String { runtimeTitles[session.id] ?? session.title }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await engine.start()
            while !Task.isCancelled {
                let began = Date()
                await refresh()
                try? await Task.sleep(for: .seconds(max(0.1, 2 - Date().timeIntervalSince(began))))
            }
        }
    }
    func stop() { task?.cancel(); task = nil; Task { await engine.stop() } }
    func refresh() async {
        await engine.updateSettings(rules)
        snapshot = await engine.poll(selectedID: selectedID)
        if selectedID == nil {
            let visible = snapshot.sessions.filter { !$0.isSystem }
            let mode = SessionSortMode(rawValue: UserDefaults.standard.string(forKey: "sessionSortMode") ?? "") ?? .recentActivity
            selectedID = SessionListOrder(visible).sorted(visible.filter { $0.parentID == nil }, mode: mode).first?.id
                ?? visible.first?.id
        }
        if let id = selectedID {
            let currentObservation = await engine.observation(id)
            let page = await engine.timeline(id)
            guard selectedID == id else { return }
            observation = currentObservation
            if pageCount == 1 { events = page.events; cursor = page.before; hasMore = page.hasMore }
            else {
                let newIDs = Set(page.events.map(\.id))
                events = (page.events + events.filter { !newIDs.contains($0.id) }).sorted { $0.timestamp > $1.timestamp }
            }
            pageNote = page.note
            if detailTab == "上下文", let path = selected?.rolloutPath { await loadComposition(id: id, path: path) }
        }
        if !titleRequested && snapshot.sessions.contains(where: { $0.title == $0.id }) {
            titleRequested = true
            titleSource.refresh { [weak self] titles in
                Task { @MainActor in self?.runtimeTitles = titles }
            }
        }
        deliverNotifications()
    }
    func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id; events = []; observation = SessionObservation(); contextHistory = ContextHistory()
        cursor = nil; pageCount = 1; hasMore = false
        Task { await refresh() }
    }
    func more() {
        guard let id = selectedID, hasMore, !loadingHistory else { return }
        loadingHistory = true
        Task {
            let page = await engine.timeline(id, before: cursor)
            guard selectedID == id else { loadingHistory = false; return }
            let ids = Set(events.map(\.id)); events += page.events.filter { !ids.contains($0.id) }
            cursor = page.before; hasMore = page.hasMore; pageCount += 1; loadingHistory = false
        }
    }
    func inspect(_ event: TraceEvent) {
        detailMaterial = nil; detailEvent = event; rawDetail = false; detailText = "正在读取内容…"; detailOffset = 0
        Task { let text = await engine.detail(event.source, readable: true); if detailEvent?.id == event.id { detailText = text } }
    }
    func inspect(_ material: ContextMaterial) {
        if material.readable {
            inspect(material.event)
        } else {
            detailEvent = material.event; rawDetail = false; detailOffset = 0
            detailText = material.preview
        }
        detailMaterial = material
    }
    func nextDetailPage() {
        guard let event = detailEvent else { return }
        detailOffset += 24_000
        Task { let text = await engine.detail(event.source, offset: detailOffset, readable: !rawDetail); if detailEvent?.id == event.id { detailText = text } }
    }
    func reloadDetail() {
        guard let event = detailEvent else { return }
        detailOffset = 0
        Task { let text = await engine.detail(event.source, readable: !rawDetail); if detailEvent?.id == event.id { detailText = text } }
    }
    func loadComposition() {
        guard let session = selected, let path = session.rolloutPath else { return }
        Task { await loadComposition(id: session.id, path: path) }
    }
    private func loadComposition(id: String, path: String) async {
        guard !contextLoading else { return }
        contextLoading = true
        let value = await contextExplorer.load(threadID: id, path: path)
        if selectedID == id { contextHistory = value }
        contextLoading = false
    }
    func markSeen(_ id: String) { Task { await engine.markSeen(id); await refresh() } }
    func earlierContext() {
        guard let id = selectedID, !loadingHistory else { return }
        loadingHistory = true
        Task {
            let result = await engine.loadEarlierContext(id)
            if selectedID == id { observation = result }
            loadingHistory = false
        }
    }
    func saveSettings() {
        UserDefaults.standard.set(notifications, forKey: "notifications")
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "rules") }
        if notifications { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }
    func openTask(_ id: String) {
        guard let url = URL(string: "codex://threads/\(id)") else { return }
        if !NSWorkspace.shared.open(url) { copyText(id) }
    }
    private func deliverNotifications() {
        for item in snapshot.attention where item.definite && !item.resolved && item.timestamp >= launchedAt {
            guard notificationIDs.insert(item.id).inserted, notifications else { continue }
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = "打开 Codex Session Atlas 查看相关任务和证据。"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
    }
}

func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
func tokenLabel(_ value: Int64) -> String { value.formatted(.number.notation(.compactName)) }
func stateColor(_ state: ExecutionState) -> Color {
    switch state {
    case .running: .blue
    case .waiting: .orange
    case .failed: .red
    case .completed: .green
    case .interrupted, .unknown, .unconfirmed: .secondary
    }
}

struct MonitorSettings: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        Form {
            Text("监控设置").font(.title2)
            LabeledContent("Codex 数据目录", value: model.home.path).textSelection(.enabled)
            Text("只读取本机会话。关闭窗口后继续监控，退出应用后停止。").foregroundStyle(.secondary)
            Toggle("为明确失败和等待用户的事件发送系统通知", isOn: $model.notifications)
            Stepper("连续失败／重复调用：\(model.rules.repeatCount) 次", value: $model.rules.repeatCount, in: 2...10)
            Stepper("重复调用观察窗口：\(model.rules.repeatMinutes) 分钟", value: $model.rules.repeatMinutes, in: 1...30)
            Stepper("上下文提示阈值：\(Int(model.rules.contextHigh * 100))%", value: $model.rules.contextHigh, in: 0.8...0.99, step: 0.01)
            Stepper("大输出阈值：\(model.rules.largeOutputBytes / 1024) KiB", value: $model.rules.largeOutputBytes, in: 32_768...1_048_576, step: 32_768)
            Stepper("无新事件提示：\(model.rules.silenceMinutes) 分钟", value: $model.rules.silenceMinutes, in: 5...60)
            Button("保存设置") { model.saveSettings(); model.showSettings = false }
                .buttonStyle(MonitorButtonStyle(selected: true))
        }.padding(24).frame(width: 540)
            .tint(MonitorStyle.accent)
            .background(MonitorStyle.paper)
            .preferredColorScheme(.light)
    }
}
