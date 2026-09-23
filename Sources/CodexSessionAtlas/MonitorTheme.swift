import SessionAtlasCore
import SwiftUI

enum MonitorStyle {
    static let canvas = Color.white
    static let paper = Color.white
    static let sidebar = Color(hex: 0xF7F7F5)
    static let surface = Color(hex: 0xF5F5F3)
    static let selection = Color(hex: 0xEAEAE7)
    static let ink = Color(hex: 0x242424)
    static let secondary = Color(hex: 0x6B6B67)
    static let line = Color(hex: 0xE7E7E3)
    static let accent = Color(hex: 0x30302E)
    static let teal = Color(hex: 0x007F78)
    static let amber = Color(hex: 0xA65308)
    static func category(_ category: ContextCategory) -> Color {
        switch category {
        case .instructions: Color(hex: 0x374151)
        case .skills: Color(hex: 0x793AC1)
        case .environment: Color(hex: 0x88603D)
        case .user: Color(hex: 0x2458C6)
        case .assistant: Color(hex: 0xB52976)
        case .toolCall: Color(hex: 0xAD5700)
        case .toolResult: Color(hex: 0x007F78)
        case .summary: Color(hex: 0x647515)
        case .attachment: Color(hex: 0x597288)
        }
    }
    static func symbol(_ category: ContextCategory) -> String {
        switch category {
        case .instructions: "text.badge.checkmark"
        case .skills: "sparkles"
        case .environment: "desktopcomputer"
        case .user: "person.fill"
        case .assistant: "text.bubble.fill"
        case .toolCall: "arrow.up.right.square.fill"
        case .toolResult: "arrow.down.left.square.fill"
        case .summary: "archivebox.fill"
        case .attachment: "paperclip"
        }
    }
    static func traceCategory(_ event: TraceEvent) -> ContextCategory {
        switch event.kind {
        case .user: .user
        case .assistant: .assistant
        case .tool: event.status == "requested" ? .toolCall : .toolResult
        case .compaction: .summary
        case .agent: .skills
        case .file: .environment
        case .lifecycle, .plan, .reasoning, .unknown: .instructions
        }
    }
}

/// The frame and hit shape belong inside the Button label, including its empty space.
struct MonitorButtonStyle: ButtonStyle {
    var tint: Color = MonitorStyle.accent
    var selected = false
    var row = false
    func makeBody(configuration: Configuration) -> some View {
        MonitorButtonBody(configuration: configuration, tint: tint, selected: selected, row: row)
    }
}

private struct MonitorButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let selected: Bool
    let row: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .padding(.horizontal, row ? 10 : 12).padding(.vertical, row ? 8 : 6)
            .frame(minHeight: row ? 48 : 36)
            .foregroundStyle(MonitorStyle.ink)
            .background(selected ? MonitorStyle.selection : (hovering || configuration.isPressed ? MonitorStyle.surface : Color.clear),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .leading) {
                if selected && row { RoundedRectangle(cornerRadius: 1).fill(tint).frame(width: 3).padding(.vertical, 9) }
            }
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .onHover { hovering = $0 }
    }
}

struct CategoryBadge: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system
    let category: ContextCategory
    var body: some View {
        Label(L(category.label, language: language), systemImage: MonitorStyle.symbol(category))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MonitorStyle.category(category))
            .padding(.vertical, 3)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct MonitorPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MonitorBadge: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system
    let text: String
    var color: Color = MonitorStyle.secondary
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(L(text, language: language)).font(.system(size: 11, weight: .medium))
        }.foregroundStyle(color).padding(.vertical, 4)
    }
}

extension View {
    func monitorDocument() -> some View {
        self.padding(.horizontal, 28).padding(.vertical, 20)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

func clockLabel(_ date: Date) -> String {
    date.formatted(.dateTime.hour().minute().second().locale(AppLanguage.current.locale))
}
func timestampLabel(_ date: Date) -> String {
    date.formatted(.dateTime.month().day().hour().minute().second().locale(AppLanguage.current.locale))
}
func percentLabel(_ count: Int, total: Int) -> String {
    guard total > 0 else { return "—" }
    let value = Double(count) / Double(total) * 100
    return value > 0 && value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
}
func ageLabel(_ date: Date?) -> String {
    guard let date else { return L("尚无事件记录") }
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return L("\(seconds) 秒前") }
    if seconds < 3600 { return L("\(seconds / 60) 分钟前") }
    if seconds < 86400 { return L("\(seconds / 3600) 小时前") }
    return L("\(seconds / 86400) 天前")
}
func characterLabel(_ count: Int) -> String {
    L("\(count.formatted(.number.locale(AppLanguage.current.locale))) 字符")
}
func friendlyTool(_ event: TraceEvent) -> String {
    if event.title == "js" || event.title == "调用请求 · js" { return L("查看或操作应用界面") }
    if event.title == "exec" || event.title == "调用请求 · exec" { return L("执行一组工具操作") }
    if !event.titleIsSource && event.title == "命令执行" { return L("运行终端命令") }
    return event.localizedTitle()
}
