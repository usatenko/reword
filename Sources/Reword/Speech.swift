import AVFoundation

/// Reads text aloud with the system's on-device voices.
@MainActor
enum Speech {
    private static let synthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String, language: String?) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate); return }
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        if let language { utterance.voice = voice(for: language) }
        synthesizer.speak(utterance)
    }

    /// Voices are keyed by language-region (zh-CN, not zh-Hans), so map the app's identifiers first.
    private static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let mapped = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "yue": "zh-HK", "fil": "fil-PH"][language] ?? language
        if let voice = AVSpeechSynthesisVoice(language: mapped) { return voice }
        let code = Locale.Language(identifier: mapped).languageCode?.identifier ?? mapped
        return AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(code + "-") || $0.language == code }
    }
}
