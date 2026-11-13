import AVFoundation
import Speech

/// Turns speech from the microphone into text using Apple's SpeechAnalyzer / SpeechTranscriber
/// (macOS 26+). Runs fully on-device; the speech model is downloaded once by the system if needed.
final class VoiceInput {

    /// Live text while the user is speaking.
    var onPartial: ((String) -> Void)?
    /// The final text once listening stops. Called on the main queue.
    var onFinal: ((String) -> Void)?
    /// A problem to show the user (permissions, unavailable recognizer, etc.).
    var onError: ((String) -> Void)?
    /// How loud the microphone is right now (0 to about 1). Called on the main queue.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var converter: AVAudioConverter?

    /// Text the transcriber has committed to.
    private var finalizedText = ""
    /// Text that may still change as more audio arrives.
    private var volatileText = ""
    private var lastText: String { finalizedText + volatileText }

    /// Bumped on every start/cancel so late callbacks from an old session are ignored.
    private var session = 0
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

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.beginRecognition()
                } else {
                    self.onError?("Microphone is off. Turn it on in System Settings > Privacy & Security > Microphone.")
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
        isListening = false

        // End the audio stream and ask the analyzer to finalize everything it has heard.
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }

        // If the transcriber never finishes, deliver what we have.
        let current = session
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.session == current, self.analyzer != nil else { return }
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
        guard isListening || analyzer != nil else { return }
        discardResult = true
        if isListening { stop() }
        teardown()
    }

    // MARK: - Recognition

    private func beginRecognition() {
        session += 1
        let current = session
        finalizedText = ""
        volatileText = ""
        isListening = true   // claim the session now so repeated presses don't start twice

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.startAnalyzer(session: current)
            } catch {
                guard self.session == current else { return }
                self.isListening = false
                self.engine.stop()
                self.engine.inputNode.removeTap(onBus: 0)
                self.teardown()
                self.onError?("Couldn't start speech recognition: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func startAnalyzer(session current: Int) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw VoiceError("Speech transcription isn't available on this Mac.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw VoiceError("Your language (\(Locale.current.identifier)) isn't supported for speech transcription.")
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )

        // Download the on-device model the first time it's needed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            if session == current { onPartial?("Downloading speech model…") }
            try await request.downloadAndInstall()
            if session == current { onPartial?("") }
        }
        guard session == current, isListening else { return }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: micFormat
        ) else {
            throw VoiceError("No compatible audio format for speech transcription.")
        }
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        guard session == current, isListening else {
            await analyzer.cancelAndFinishNow()
            return
        }

        self.analyzer = analyzer
        converter = micFormat == analyzerFormat ? nil : AVAudioConverter(from: micFormat, to: analyzerFormat)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Results: volatile text replaces the previous guess; final text is appended.
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.session == current else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedText += text
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                    let shown = self.lastText.trimmingCharacters(in: .whitespaces)
                    self.onPartial?(shown)
                    if !shown.isEmpty, self.isListening {
                        self.scheduleSilenceStop()   // a pause after speech ends the question
                    }
                }
            } catch {
                // Fall through and deliver whatever we have.
            }
            guard let self, self.session == current else { return }
            self.finish()
        }

        let converter = self.converter
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
            self?.reportLevel(of: buffer)
            if let converted = Self.convert(buffer, with: converter, to: analyzerFormat) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }

        engine.prepare()
        try engine.start()

        analyzerTask = Task {
            try? await analyzer.start(inputSequence: stream)
        }
        scheduleSilenceStop(after: 8)   // nothing said at all: stop after 8 seconds
    }

    /// Converts a microphone buffer into the format the analyzer wants.
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
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

    /// Releases the analyzer and invalidates any callbacks still in flight.
    private func teardown() {
        session += 1
        silenceWork?.cancel()
        silenceWork = nil
        fallbackWork?.cancel()
        fallbackWork = nil
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        converter = nil
        finalizedText = ""
        volatileText = ""
    }

    /// Cleans up and reports whatever was heard.
    private func finish() {
        if isListening { stop() }
        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        let deliver = !discardResult
        teardown()
        if deliver {
            onFinal?(text)
        }
    }
}

private struct VoiceError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
