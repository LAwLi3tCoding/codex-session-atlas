import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, simplifiedChinese = "zh-Hans", english = "en"

    public static let preferenceKey = "appLanguage"
    public static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system
    }
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        return Self.resolve(preferredLanguages: Locale.preferredLanguages)
    }
    public static func resolve(preferredLanguages: [String]) -> AppLanguage {
        preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .simplifiedChinese : .english
    }
    public var locale: Locale { Locale(identifier: resolved == .simplifiedChinese ? "zh_CN" : "en_US") }
    public var nativeName: String {
        switch self {
        case .system: L("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

/// Localize app-owned copy only. Session text, tool arguments, output and source paths
/// must never be passed here. Canonical cached messages stay unchanged on disk.
public func L(_ text: String, language: AppLanguage = .current) -> String {
    Localization.text(text, language: language)
}

public enum Localization {
    private struct Template: Sendable {
        let source: String
        let target: String
        let regex: NSRegularExpression
        let arguments: [String]
    }
    private static let marker = try! NSRegularExpression(pattern: #"\{[0-9]+\}"#)
    private static let templates: [Template] = LocalizationCatalog.english.compactMap { source, target in
        let matches = marker.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return nil }
        var pattern = "\\A"; var position = source.startIndex; var arguments: [String] = []
        for match in matches {
            guard let range = Range(match.range, in: source) else { return nil }
            pattern += NSRegularExpression.escapedPattern(for: String(source[position..<range.lowerBound])) + "(.*?)"
            arguments.append(String(source[range])); position = range.upperBound
        }
        pattern += NSRegularExpression.escapedPattern(for: String(source[position...])) + "\\z"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        return Template(source: source, target: target, regex: regex, arguments: arguments)
    }.sorted { $0.source.count == $1.source.count ? $0.source < $1.source : $0.source.count > $1.source.count }

    public static func text(_ text: String, language: AppLanguage) -> String {
        guard language.resolved == .english else { return text }
        if let translated = LocalizationCatalog.english[text] { return translated }
        // Most labels and source metadata are already language-neutral.
        guard text.range(of: #"[\u3400-\u9FFF]"#, options: .regularExpression) != nil else { return text }
        for template in templates {
            guard let match = template.regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            var arguments: [String: String] = [:]
            for (index, key) in template.arguments.enumerated() {
                if let range = Range(match.range(at: index + 1), in: text) { arguments[key] = String(text[range]) }
            }
            // Substitute once, so braces or catalog words in source arguments remain literal.
            var result = template.target
            for marker in marker.matches(in: template.target, range: NSRange(template.target.startIndex..., in: template.target)).reversed() {
                if let range = Range(marker.range, in: result), let value = arguments[String(result[range])] {
                    result.replaceSubrange(range, with: value)
                }
            }
            return result
        }
        return text
    }

    /// Error wrappers contain other app-owned errors; arbitrary OS error details are retained.
    public static func diagnostic(_ text: String, language: AppLanguage = .current) -> String {
        for prefix in ["会话索引读取失败，显示上次快照：", "分页历史读取失败，保留上次状态并继续采集日志：", "无法读取源记录："] {
            if text.hasPrefix(prefix) {
                let detail = String(text.dropFirst(prefix.count))
                return L(prefix + "{detail}", language: language).replacingOccurrences(of: "{detail}", with: L(detail, language: language))
            }
        }
        return L(text, language: language)
    }

    public static func catalogIssues() -> [String] {
        let invalid = LocalizationCatalog.english.compactMap { source, target in
            func markers(_ value: String) -> [String] {
                marker.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
                    Range($0.range, in: value).map { String(value[$0]) }
                }.sorted()
            }
            return target.isEmpty || target.range(of: #"[\u3400-\u9FFF]"#, options: .regularExpression) != nil || markers(source) != markers(target)
                ? source : nil
        }
        let rendering = templates.compactMap { template -> String? in
            var source = template.source; var expected = template.target
            for (index, key) in template.arguments.enumerated() {
                let value = "value-\(index) 🚀 原文 {99} $1\n"
                source = source.replacingOccurrences(of: key, with: value)
                expected = expected.replacingOccurrences(of: key, with: value)
            }
            return text(source, language: .english) == expected ? nil : template.source
        }
        return Array(Set(invalid + rendering)).sorted()
    }
}
