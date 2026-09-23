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
        model.languageDidChange = { [weak self] in self?.installMenus() }
        DispatchQueue.main.async { [weak self] in self?.installMenus() }
        model.start()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationDidBecomeActive(_ notification: Notification) { installMenus() }
    private func installMenus() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: L(title), action: nil, keyEquivalent: "")
            let menu = NSMenu(title: L(title)); item.submenu = menu; main.addItem(item); return menu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil,
                  modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: L(title), action: action, keyEquivalent: key)
            item.target = target; item.keyEquivalentModifierMask = modifiers; menu.addItem(item)
        }
        let app = menu("Codex Session Atlas")
        item(app, "关于 Codex Session Atlas", #selector(showAbout), target: self)
        item(app, "监控设置", #selector(showSettings), ",", target: self)
        let languageItem = NSMenuItem(title: "Language / 语言", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: languageItem.title)
        for language in AppLanguage.allCases {
            let option = NSMenuItem(title: language.nativeName, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            option.target = self; option.representedObject = language.rawValue
            option.state = model.language == language ? .on : .off; languageMenu.addItem(option)
        }
        languageItem.submenu = languageMenu; app.addItem(languageItem)
        app.addItem(.separator())
        item(app, "隐藏 Codex Session Atlas", #selector(NSApplication.hide(_:)), "h")
        item(app, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        item(app, "全部显示", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        item(app, "退出 Codex Session Atlas", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("文件")
        item(file, "关闭窗口", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("编辑")
        item(edit, "撤销", Selector(("undo:")), "z")
        item(edit, "重做", Selector(("redo:")), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        item(edit, "剪切", #selector(NSText.cut(_:)), "x")
        item(edit, "复制", #selector(NSText.copy(_:)), "c")
        item(edit, "粘贴", #selector(NSText.paste(_:)), "v")
        item(edit, "全选", #selector(NSText.selectAll(_:)), "a")
        let windows = menu("窗口")
        item(windows, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(windows, "缩放", #selector(NSWindow.performZoom(_:)))
        windows.addItem(.separator())
        item(windows, "全部置于前台", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windows
        let help = menu("帮助")
        item(help, "使用手册", #selector(openGuide), target: self)
        item(help, "查看 GitHub 项目", #selector(openRepository), target: self)
        NSApp.helpMenu = help; NSApp.mainMenu = main
    }
    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let language = AppLanguage(rawValue: value) else { return }
        model.language = language
    }
    @objc private func showSettings() { window?.makeKeyAndOrderFront(nil); model.showSettings = true }
    @objc private func showAbout() { window?.makeKeyAndOrderFront(nil); model.showAbout = true }
    @objc private func openGuide() {
        let file = model.language.resolved == .english ? "usage.md" : "usage.zh-CN.md"
        NSWorkspace.shared.open(URL(string: "https://github.com/LAwLi3tCoding/codex-session-atlas/blob/main/docs/" + file)!)
    }
    @objc private func openRepository() { NSWorkspace.shared.open(URL(string: "https://github.com/LAwLi3tCoding/codex-session-atlas")!) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); sender.activate(ignoringOtherApps: true); return true
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var language = AppLanguage.current {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.preferenceKey)
            languageDidChange?()
            if detailEvent != nil { loadDetail() }
        }
    }
    var languageDidChange: (() -> Void)?
    @Published var showAbout = false
    @Published var detailHasMore = false
    private var detailRequest = UUID()
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
        detailMaterial = nil; detailEvent = event; rawDetail = false; detailOffset = 0
        loadDetail()
    }
    func inspect(_ material: ContextMaterial) {
        detailEvent = material.event; detailMaterial = material; rawDetail = false; detailOffset = 0
        loadDetail()
    }
    func nextDetailPage() {
        guard detailHasMore else { return }
        detailOffset += 24_000; loadDetail()
    }
    func reloadDetail() { detailOffset = 0; loadDetail() }
    private func loadDetail() {
        let request = UUID(); detailRequest = request; detailHasMore = false
        guard let event = detailEvent else { return }
        if let material = detailMaterial, !material.readable {
            detailText = material.localizedPreview(language: language); return
        }
        detailText = L("正在读取内容…", language: language)
        let offset = detailOffset; let readable = !rawDetail; let language = language
        Task {
            let page = await engine.detailPage(event.source, offset: offset, readable: readable, language: language)
            guard detailRequest == request, detailEvent?.id == event.id else { return }
            detailText = page.text; detailHasMore = page.hasMore
        }
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
            content.title = L(item.title, language: language)
            content.body = L("打开 Codex Session Atlas 查看相关任务和证据。")
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
    }
}

func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
func tokenLabel(_ value: Int64) -> String { value.formatted(.number.notation(.compactName).locale(AppLanguage.current.locale)) }
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
        VStack(alignment: .leading, spacing: 16) {
            Text(L("监控设置")).font(.title2)
            Picker("Language / 语言", selection: $model.language) {
                Text(L("跟随系统")).tag(AppLanguage.system)
                Text("简体中文").tag(AppLanguage.simplifiedChinese)
                Text("English").tag(AppLanguage.english)
            }.pickerStyle(.segmented)
            Text(L("语言立即生效。会话原文、代码和工具输出保持原样。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            LabeledContent(L("Codex 数据目录"), value: model.home.path).textSelection(.enabled).lineLimit(2)
            Text(L("只读取本机会话。关闭窗口后继续监控，退出应用后停止。")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(L("为明确失败和等待用户的事件发送系统通知"), isOn: $model.notifications)
            Stepper(L("连续失败／重复调用：\(model.rules.repeatCount) 次"), value: $model.rules.repeatCount, in: 2...10)
            Stepper(L("重复调用观察窗口：\(model.rules.repeatMinutes) 分钟"), value: $model.rules.repeatMinutes, in: 1...30)
            Stepper(L("上下文提示阈值：\(Int(model.rules.contextHigh * 100))%"), value: $model.rules.contextHigh, in: 0.8...0.99, step: 0.01)
            Stepper(L("大输出阈值：\(model.rules.largeOutputBytes / 1024) KiB"), value: $model.rules.largeOutputBytes, in: 32_768...1_048_576, step: 32_768)
            Stepper(L("无新事件提示：\(model.rules.silenceMinutes) 分钟"), value: $model.rules.silenceMinutes, in: 5...60)
            HStack {
                Spacer()
                Button(L("保存设置")) { model.saveSettings(); model.showSettings = false }
                    .buttonStyle(MonitorButtonStyle(selected: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 640)
            .environment(\.locale, model.language.locale)
            .tint(MonitorStyle.accent)
            .background(MonitorStyle.paper)
            .preferredColorScheme(.light)
    }
}

struct MonitorAbout: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 80, height: 80)
            Text("Codex Session Atlas").font(.title2)
            Text(L("会话 · 轨迹 · 上下文")).foregroundStyle(.secondary)
            Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
            Text("© 2026 LAwLi3tCoding · MIT").font(.caption).foregroundStyle(.secondary)
            Link(L("查看 GitHub 项目"), destination: URL(string: "https://github.com/LAwLi3tCoding/codex-session-atlas")!)
            Button(L("关闭窗口")) { model.showAbout = false }.keyboardShortcut(.cancelAction)
        }.padding(32).frame(width: 400).buttonStyle(MonitorButtonStyle())
            .environment(\.locale, model.language.locale)
    }
}
