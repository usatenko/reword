import Foundation
import NaturalLanguage

/// A language the app offers in its pickers.
struct AppLanguage: Identifiable, Hashable {
    let id: String          // BCP-47 identifier, e.g. "en", "zh-Hans"
    let name: String

    var language: Locale.Language { Locale.Language(identifier: id) }

    static let all: [AppLanguage] = [
        // Hy-MT2's 33 languages and 5 regional languages/dialects (model card).
        "en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "uk",
        "pl", "cs", "nl", "tr", "ar", "fa", "he", "hi", "bn", "gu", "mr", "ta", "te", "ur",
        "vi", "th", "id", "ms", "fil", "km", "my", "kk", "mn", "ug", "bo", "yue",
    ].map { id in
        AppLanguage(id: id, name: Locale.current.localizedString(forIdentifier: id) ?? id)
    }

    static func named(_ id: String) -> AppLanguage {
        all.first { $0.id == id } ?? AppLanguage(id: id, name: Locale.current.localizedString(forIdentifier: id) ?? id)
    }
}

enum LanguageTools {
    /// Detects the dominant language of `text` on-device with NaturalLanguage.
    static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage, lang != .undetermined else { return nil }
        return lang.rawValue
    }

    /// Same language for translation purposes: equal language code, and equal script for Chinese.
    static func same(_ a: String, _ b: String) -> Bool {
        let la = Locale.Language(identifier: a), lb = Locale.Language(identifier: b)
        guard la.languageCode == lb.languageCode else { return false }
        if la.languageCode?.identifier == "zh" {
            return (la.script ?? .init("Hans")) == (lb.script ?? .init("Hans"))
        }
        return true
    }

    /// Easydict-style target choice: text in the first language goes to the second, everything else to the first.
    static func target(for source: String, first: String, second: String) -> String {
        same(source, first) ? second : first
    }

    static func displayName(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// Flag shown next to a language name, Easydict-style.
    static func flag(_ id: String) -> String {
        let regions: [String: String] = [
            "en": "GB", "zh-Hans": "CN", "zh-Hant": "TW", "ja": "JP", "ko": "KR", "fr": "FR", "de": "DE",
            "es": "ES", "it": "IT", "pt": "PT", "ru": "RU", "uk": "UA", "pl": "PL", "cs": "CZ", "nl": "NL",
            "tr": "TR", "ar": "SA", "fa": "IR", "he": "IL", "hi": "IN", "bn": "BD", "gu": "IN", "mr": "IN",
            "ta": "IN", "te": "IN", "ur": "PK", "vi": "VN", "th": "TH", "id": "ID", "ms": "MY", "fil": "PH",
            "km": "KH", "my": "MM", "kk": "KZ", "mn": "MN", "ug": "CN", "bo": "CN", "yue": "HK",
        ]
        let key = regions[id] != nil ? id : (Locale.Language(identifier: id).languageCode?.identifier ?? id)
        guard let region = regions[key] ?? (id.hasPrefix("zh") ? "CN" : nil) else { return "🌐" }
        return String(String.UnicodeScalarView(region.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }
}
