import Foundation

/// Only formats the already-visible preview. Opening a record still reads its original source.
struct RecordExcerpt {
    let text: String
    let code: Bool

    init(_ source: String, toolOutput: Bool = false) {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if toolOutput {
            var lines = text.components(separatedBy: "\n")
            while let line = lines.first,
                  line.isEmpty || line == "Script completed" || line == "Output:" || line.hasPrefix("Wall time") {
                lines.removeFirst()
            }
            if !lines.isEmpty { text = lines.joined(separator: "\n") }
        }
        for _ in 0..<2 {
            guard let decoded = try? JSONDecoder().decode(String.self, from: Data(text.utf8)) else { break }
            text = decoded
        }
        if text.hasPrefix("{") || text.hasPrefix("[") {
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            for key in ["title", "description", "cmd", "command", "query", "prompt", "text", "code"] {
                let pattern = "\"" + key + "\"\\s*:\\s*(\"(?:\\\\.|[^\"\\\\])*\")"
                let match = text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
                    .flatMap { pair in pair.range(of: ":").map { String(pair[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } }
                // Use complete string values only; never repair a truncated JSON string.
                let value = object?[key] as? String ?? match.flatMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }
                if let value, !value.isEmpty {
                    self.text = value
                    self.code = ["cmd", "command", "code"].contains(key)
                    return
                }
            }
            if text.contains("\"code\"") { text = L("执行脚本，展开查看代码与参数。") }
            else if text.contains("\"cmd\"") || text.contains("\"command\"") { text = L("终端命令，展开查看命令与参数。") }
            else { text = L("结构化内容，展开查看完整记录。") }
        }
        let readable = text.replacingOccurrences(of: #"(?m)^</?[A-Za-z_][^>]*>\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.text = readable.isEmpty ? text : readable
        self.code = false
    }
}

import SessionAtlasCore
import SwiftUI

struct MonitorRecordLabel: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system
    let title: String
    let preview: String
    let category: ContextCategory
    let label: String
    let timestamp: Date
    let metadata: String
    var failed = false
    var compact = false

    var body: some View {
        let excerpt = RecordExcerpt(preview, toolOutput: category == .toolResult)
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: MonitorStyle.symbol(category))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MonitorStyle.category(category))
                .frame(width: 30, height: 30)
                .background(MonitorStyle.category(category).opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(L(label, language: language)).foregroundStyle(MonitorStyle.category(category))
                    if failed { Label(L("失败"), systemImage: "exclamationmark.circle.fill").foregroundStyle(.red) }
                    Spacer(minLength: 10)
                    Text(clockLabel(timestamp)).monospacedDigit().foregroundStyle(MonitorStyle.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(MonitorStyle.secondary)
                }.font(.system(size: 11, weight: .medium))
                if title != label {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                if !excerpt.text.isEmpty {
                    Text(excerpt.text)
                        .font(.system(size: 13, design: excerpt.code || category == .toolCall ? .monospaced : .default))
                        .foregroundStyle(MonitorStyle.ink.opacity(0.85)).lineSpacing(3)
                        .lineLimit(compact ? 1 : 2).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !metadata.isEmpty {
                    Text(metadata).font(.system(size: 10)).foregroundStyle(MonitorStyle.secondary).lineLimit(1)
                }
            }
        }.padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading).contentShape(Rectangle())
    }
}

struct MonitorSearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(MonitorStyle.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
        }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 36)
            .background(MonitorStyle.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MonitorRecordBody: View {
    let text: String
    let raw: Bool
    let code: Bool

    private var fields: [String: Any]? {
        guard !raw else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let fields, !fields.isEmpty {
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(MonitorStyle.secondary)
                        bodyText(value(fields[key]!), code: true)
                    }
                }
            } else {
                bodyText(text, code: raw || code)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func bodyText(_ value: String, code: Bool) -> some View {
        if code {
            Text(value).font(.system(size: 12, design: .monospaced)).lineSpacing(4).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(MonitorStyle.surface, in: RoundedRectangle(cornerRadius: 10))
        } else {
            MonitorProse(text: value)
        }
    }
    private func value(_ value: Any) -> String {
        if let string = value as? String { return string }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }
}

/// A local reader for headings, paragraphs and fenced code. The raw record remains available.
private struct MonitorProse: View {
    let text: String
    private struct Block: Identifiable {
        let id: Int
        let text: String
        let heading: Int
        let code: Bool
    }
    private var blocks: [Block] {
        var result: [Block] = []
        var lines: [String] = []
        var fence: String?
        func flush() {
            guard !lines.isEmpty else { return }
            result.append(Block(id: result.count, text: lines.joined(separator: "\n"), heading: 0, code: fence != nil))
            lines = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let activeFence = fence {
                if trimmed.hasPrefix(activeFence) { flush(); fence = nil }
                else { lines.append(line) }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); fence = String(trimmed.prefix(3))
            } else {
                let level = line.prefix(while: { $0 == "#" }).count
                if (1...6).contains(level), line.dropFirst(level).hasPrefix(" ") {
                    flush()
                    result.append(Block(id: result.count, text: String(line.dropFirst(level + 1)), heading: level, code: false))
                } else if trimmed.isEmpty { flush() }
                else { lines.append(line) }
            }
        }
        flush()
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { block in
                if block.code {
                    Text(block.text).font(.system(size: 12, design: .monospaced)).lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(MonitorStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text((try? AttributedString(markdown: block.text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                        .font(.system(size: block.heading > 0 ? (block.heading <= 2 ? 18 : 15) : 14,
                                      weight: block.heading > 0 ? .semibold : .regular))
                        .lineSpacing(6).padding(.top, block.heading > 0 ? 8 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.textSelection(.enabled)
    }
}
