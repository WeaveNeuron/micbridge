import Foundation

/// The two interface languages. Every user-visible sentence is written in
/// both, side by side at the call site (`tr`), so neither can go missing
/// and a sentence and its translation are reviewed together.
enum Lang: String, CaseIterable, Equatable {
    case zh, en

    /// Previews and tests pin a language; the app follows the system.
    static var override: Lang?
    static var current: Lang { override ?? system }
    /// The first of the user's preferred languages this app has: Simplified
    /// (or any) Chinese, else English.
    static let system: Lang = {
        let preferred = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .zh : .en
    }()
}

/// The sentence in the current language. Chinese gets a space between CJK
/// and Latin runs (`cjkSpaced`), so names can be interpolated without
/// thinking about spacing.
func tr(_ zh: String, _ en: String) -> String {
    Lang.current == .zh ? cjkSpaced(zh) : en
}

/// Runs `body` with the language pinned (previews, tests).
func withLanguage<T>(_ lang: Lang, _ body: () throws -> T) rethrows -> T {
    let saved = Lang.override
    Lang.override = lang
    defer { Lang.override = saved }
    return try body()
}

/// Inserts a space between CJK ideographs and Latin letters or digits
/// ("已连接Studio的麦克风" → "已连接 Studio 的麦克风"). Existing spaces are kept.
func cjkSpaced(_ text: String) -> String {
    func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }
    func isLatin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
    var result = ""
    var previous: Character?
    for c in text {
        if let p = previous, (isCJK(p) && isLatin(c)) || (isLatin(p) && isCJK(c)) { result.append(" ") }
        result.append(c); previous = c
    }
    return result
}
