import Foundation

// The language of every Toss window, menu and toast (2026-10-29: follow the
// Mac by default, with one place to change it). Settings → Language: Follow System / Simplified Chinese / English. Diagnostics data and
// logs stay English. Only the Toss app itself reads the setting; tests and command-line entries
// (no bundle identifier) always get English, so their assertions don't depend on this Mac's language.
enum AppLanguage: String, CaseIterable {
    case system, chinese = "zh-Hans", english = "en"

    static let key = "Toss.language"
    static let appBundleIdentifier = "io.github.ashzene.toss"

    static var choice: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    // Chinese when chosen, or when following a system whose first language is Chinese.
    static func resolvesToChinese(choice: AppLanguage, preferred: [String]) -> Bool {
        switch choice {
        case .chinese: return true
        case .english: return false
        case .system: return (preferred.first ?? "").lowercased().hasPrefix("zh")
        }
    }

    // Set by the render harness so every screen can be drawn in both languages.
    nonisolated(unsafe) static var override: Bool?

    static var isChinese: Bool {
        if let override { return override }
        guard Bundle.main.bundleIdentifier == appBundleIdentifier else { return false }
        return resolvesToChinese(choice: choice, preferred: Locale.preferredLanguages)
    }
}

// One visible string in both languages: English first, as in the source, then Simplified Chinese.
func L(_ english: String, _ chinese: String) -> String { AppLanguage.isChinese ? chinese : english }
