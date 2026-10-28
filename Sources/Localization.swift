import Foundation

enum L10n {
    // The override is used by preview / test commands; the installed app follows macOS.
    static var languageOverride: String?
    static func isKorean(_ languages: [String]) -> Bool {
        languages.first?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first == "ko"
    }
    static var korean: Bool { isKorean(languageOverride.map { [$0] } ?? Locale.preferredLanguages) }
    static var locale: Locale { Locale(identifier: korean ? "ko_KR" : "en_US") }
    static func text(_ ko: String, _ en: String) -> String { korean ? ko : en }
}
