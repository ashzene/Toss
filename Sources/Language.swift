import Foundation

// The language of every Toss window, menu and toast (Ashley 2026-10-29: 「默认是跟随电脑设置，但是要有一个
// 地方能够更改语言设置」; 2026-11-05: the same languages as Tendedero, English when the system's isn't one).
// Diagnostics data and logs stay English. Only the Toss app itself reads the setting; tests and
// command-line entries (no bundle identifier) always get English, so their assertions don't depend
// on this Mac's language.
enum AppLanguage: String, CaseIterable {
    case system, chinese = "zh-Hans", english = "en", azerbaijani = "az", spanish = "es", french = "fr",
         galician = "gl", hindi = "hi", japanese = "ja", korean = "ko", portuguese = "pt-BR", turkish = "tr"

    static let key = "Toss.language"
    static let appBundleIdentifier = "io.github.ashzene.toss"

    // Named in its own language so it can be found whatever the current one is.
    var nativeName: String {
        switch self {
        case .system: return ""
        case .chinese: return "简体中文"
        case .english: return "English"
        case .azerbaijani: return "Azərbaycan dili"
        case .spanish: return "Español"
        case .french: return "Français"
        case .galician: return "Galego"
        case .hindi: return "हिन्दी"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .portuguese: return "Português (Brasil)"
        case .turkish: return "Türkçe"
        }
    }

    static var choice: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    // Following the system looks only at its first language; one Toss doesn't have is English.
    static func resolve(choice: AppLanguage, preferred: [String]) -> AppLanguage {
        guard choice == .system else { return choice }
        let base = (preferred.first ?? "").lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        switch base {
        case "zh": return .chinese
        case "pt": return .portuguese
        default: return allCases.first { $0 != .system && $0.rawValue == base } ?? .english
        }
    }

    static func resolvesToChinese(choice: AppLanguage, preferred: [String]) -> Bool {
        resolve(choice: choice, preferred: preferred) == .chinese
    }

    // Set by the render harness so every screen can be drawn in both languages.
    nonisolated(unsafe) static var override: Bool?
    // Holds the active language while the saved preference is being cleared.
    nonisolated(unsafe) static var forced: AppLanguage?

    static var current: AppLanguage {
        if let forced { return forced }
        if let override { return override ? .chinese : .english }
        guard Bundle.main.bundleIdentifier == appBundleIdentifier else { return .english }
        return resolve(choice: choice, preferred: Locale.preferredLanguages)
    }

    static var isChinese: Bool { current == .chinese }
}

// The languages besides English and Chinese live in Assets/Localization/<code>.json, keyed by the
// English string. An interpolated string is keyed by its template ("Unlock the {0}"), matched here
// against the finished English text. Anything missing falls back to English.
enum Translations {
    nonisolated(unsafe) static var directory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Localization")
    private struct Table {
        let exact: [String: String]
        let templates: [(pattern: NSRegularExpression, text: String)]
    }
    nonisolated(unsafe) private static var tables: [AppLanguage: Table] = [:]
    private static let lock = NSLock()

    private static func table(_ language: AppLanguage) -> Table {
        lock.lock(); defer { lock.unlock() }
        if let cached = tables[language] { return cached }
        var entries: [String: String] = [:]
        if let url = directory?.appendingPathComponent(language.rawValue + ".json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) { entries = decoded }
        // Longest first: the template with the most fixed text is the most specific match.
        let templates = entries.keys.filter { $0.contains("{0}") }.sorted { $0.count > $1.count }.compactMap { key -> (NSRegularExpression, String)? in
            let source = NSRegularExpression.escapedPattern(for: key)
                .replacingOccurrences(of: #"\\\{\d+\\\}"#, with: "(.*)", options: .regularExpression)
            guard let pattern = try? NSRegularExpression(pattern: "^" + source + "$", options: .dotMatchesLineSeparators),
                  let text = entries[key] else { return nil }
            return (pattern, text)
        }
        let table = Table(exact: entries, templates: templates.map { (pattern: $0.0, text: $0.1) })
        tables[language] = table
        return table
    }

    static func text(_ english: String, language: AppLanguage = AppLanguage.current) -> String {
        guard language != .english, language != .chinese, language != .system else { return english }
        let table = table(language)
        if let exact = table.exact[english] { return exact }
        let whole = NSRange(english.startIndex..., in: english)
        for (pattern, text) in table.templates {
            guard let match = pattern.firstMatch(in: english, range: whole) else { continue }
            var result = text
            for group in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: group), in: english) else { continue }
                result = result.replacingOccurrences(of: "{\(group - 1)}", with: String(english[range]))
            }
            return result
        }
        return english
    }
}

// One visible string: English first, as in the source, then Simplified Chinese.
func L(_ english: String, _ chinese: String) -> String {
    let language = AppLanguage.current
    return language == .chinese ? chinese : Translations.text(english, language: language)
}
