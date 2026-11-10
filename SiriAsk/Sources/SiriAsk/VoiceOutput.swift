import AVFoundation

/// Reads answers aloud. Uses Gradium when `.env` has a key and voice, otherwise the macOS voice.
/// If Gradium fails, it falls back to the macOS voice.
final class VoiceOutput: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let gradium = GradiumVoice()

    /// Called on the main queue when audio starts, with which voice is playing.
    var onAudioStarted: ((String) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        gradium.onAudioStarted = { [weak self] in self?.onAudioStarted?("Gradium") }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.onAudioStarted?("macOS voice") }
    }

    func speak(_ text: String) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Read the config each time, so edits to .env take effect without rebuilding.
        if let config = GradiumVoice.loadConfig() {
            gradium.speak(trimmed, config: config) { [weak self] in
                self?.speakWithSystemVoice(trimmed)
            }
        } else {
            speakWithSystemVoice(trimmed)
        }
    }

    func stop() {
        gradium.stop()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}
