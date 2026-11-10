import AVFoundation
import Speech

/// Turns speech from the microphone into text, using Apple's speech recognition.
/// Prefers on-device recognition when the Mac supports it, so audio stays local.
final class VoiceInput {

    /// Live text while the user is speaking.
    var onPartial: ((String) -> Void)?
    /// The final text once listening stops. Called on the main queue.
    var onFinal: ((String) -> Void)?
    /// A problem to show the user (permissions, unavailable recognizer, etc.).
    var onError: ((String) -> Void)?
    /// How loud the microphone is right now (0 to about 1). Called on the main queue.
    var onLevel: ((Float) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastText = ""
    private var discardResult = false
    private var silenceWork: DispatchWorkItem?
    private var fallbackWork: DispatchWorkItem?
    private(set) var isListening = false

    func toggle() {
        isListening ? stop() : start()
    }

    func start() {
        guard !isListening else { return }
        discardResult = false

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.onError?("Speech recognition is off. Turn it on in System Settings > Privacy & Security > Speech Recognition.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            self.beginRecognition()
                        } else {
                            self.onError?("Microphone is off. Turn it on in System Settings > Privacy & Security > Microphone.")
                        }
                    }
                }
            }
        }
    }

    /// Stops capturing audio. The final text is delivered through `onFinal`.
    func stop() {
        guard isListening else { return }
        silenceWork?.cancel()
        silenceWork = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isListening = false

        // If the recognizer never sends a final result, deliver what we have.
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.request != nil || self.task != nil else { return }
            self.finish()
        }
        fallbackWork = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: fallback)
    }

    /// Stops listening after a pause in speech. Called again every time new words arrive.
    private func scheduleSilenceStop(after seconds: Double = 1.5) {
        silenceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isListening else { return }
            self.stop()
        }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Stops listening and throws away anything heard so far. Nothing is delivered through `onFinal`.
    func cancel() {
        guard isListening || task != nil else { return }
        discardResult = true
        if isListening { stop() }
        task?.cancel()
        task = nil
        request = nil
        lastText = ""
    }

    private func beginRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            onError?("Speech recognition isn't available right now.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        lastText = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            self?.reportLevel(of: buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            onError?("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }

        isListening = true
        scheduleSilenceStop(after: 8)   // nothing said at all: stop after 8 seconds
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.lastText = result.bestTranscription.formattedString
                    self.onPartial?(self.lastText)
                    if !self.lastText.isEmpty {
                        self.scheduleSilenceStop()   // a pause after speech ends the question
                    }
                    if result.isFinal {
                        self.finish()
                        return
                    }
                }
                if error != nil {
                    self.finish()
                }
            }
        }
    }

    /// Measures the loudness of one audio buffer and reports it on the main queue.
    private func reportLevel(of buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for i in 0..<count {
            sum += channel[i] * channel[i]
        }
        let rms = (sum / Float(count)).squareRoot()
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(rms)
        }
    }

    /// Cleans up and reports whatever was heard.
    private func finish() {
        silenceWork?.cancel()
        silenceWork = nil
        fallbackWork?.cancel()
        fallbackWork = nil
        if isListening { stop() }
        task?.cancel()
        task = nil
        request = nil
        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastText = ""
        if !discardResult {
            onFinal?(text)
        }
    }
}
