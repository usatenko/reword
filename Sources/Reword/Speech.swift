import AVFoundation

/// Reads text aloud with the system's on-device voices.
@MainActor
enum Speech {
    private static let synthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String, language: String?) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate); return }
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        if let language { utterance.voice = AVSpeechSynthesisVoice(language: language) }
        synthesizer.speak(utterance)
    }
}
