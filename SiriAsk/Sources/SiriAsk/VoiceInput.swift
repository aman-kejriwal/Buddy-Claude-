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
    /// Called on the main queue when voice input becomes active (leaves `.idle`) or goes back to `.idle`.
    var onActiveChanged: ((Bool) -> Void)?

    /// Where one listening session is. Every change goes through `state`, so the UI can't drift.
    enum State: Equatable {
        case idle
        case awaitingPermission   // asked for microphone access, waiting for the answer
        case preparing            // setting up the analyzer (may download the speech model)
        case listening            // microphone is on, text is arriving
        case finalizing           // microphone off, waiting for the last text
    }

    private(set) var state: State = .idle {
        didSet {
            let wasActive = oldValue != .idle, isActive = state != .idle
            if wasActive != isActive { onActiveChanged?(isActive) }
        }
    }

    /// True whenever a session is underway, in any state other than `.idle`.
    var isActive: Bool { state != .idle }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?

    /// Text the transcriber has committed to.
    private var finalizedText = ""
    /// Text that may still change as more audio arrives.
    private var volatileText = ""
    private var lastText: String { finalizedText + volatileText }

    /// Bumped on every start and teardown so late callbacks from an old session are ignored.
    private var session = 0
    private var silenceWork: DispatchWorkItem?
    private var fallbackWork: DispatchWorkItem?

    func toggle() {
        state == .idle ? start() : stop()
    }

    func start() {
        guard state == .idle else { return }
        session += 1
        let current = session
        state = .awaitingPermission

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                // Cancelled (e.g. the panel was hidden) while the permission prompt was up.
                guard let self, self.session == current, self.state == .awaitingPermission else { return }
                if granted {
                    self.beginRecognition(session: current)
                } else {
                    self.state = .idle
                    self.onError?("Microphone is off. Turn it on in System Settings > Privacy & Security > Microphone.")
                }
            }
        }
    }

    /// Stops capturing audio. If the microphone was on, the final text is delivered through `onFinal`.
    /// If it hadn't turned on yet, the session just ends (nothing was heard).
    func stop() {
        switch state {
        case .idle, .finalizing:
            return
        case .awaitingPermission, .preparing:
            abort()
            return
        case .listening:
            break
        }

        silenceWork?.cancel()
        silenceWork = nil
        stopAudio()
        state = .finalizing

        // End the audio stream and ask the analyzer to finalize everything it has heard.
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }

        // If the transcriber never finishes, deliver what we have.
        let current = session
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.session == current, self.state == .finalizing else { return }
            self.finish()
        }
        fallbackWork = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: fallback)
    }

    /// Stops listening after a pause in speech. Called again every time new words arrive.
    private func scheduleSilenceStop(after seconds: Double = 1.5) {
        silenceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .listening else { return }
            self.stop()
        }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Ends the session from any state and throws away anything heard. Nothing is delivered through `onFinal`.
    func cancel() {
        guard state != .idle else { return }
        abort()
    }

    // MARK: - Recognition

    private func beginRecognition(session current: Int) {
        finalizedText = ""
        volatileText = ""
        state = .preparing

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.startAnalyzer(session: current)
            } catch {
                guard self.session == current else { return }
                self.abort()
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
        guard session == current, state == .preparing else { return }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        // A zero format means there is no usable input device right now. AVAudioEngine raises an
        // Objective-C exception (not a Swift error) if we tap or start with it.
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw VoiceError("No microphone is available.")
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: micFormat
        ) else {
            throw VoiceError("No compatible audio format for speech transcription.")
        }
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        guard session == current, state == .preparing else {
            await analyzer.cancelAndFinishNow()
            return
        }

        self.analyzer = analyzer

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
                    if !shown.isEmpty, self.state == .listening {
                        self.scheduleSilenceStop()   // a pause after speech ends the question
                    }
                }
            } catch {
                // Fall through and deliver whatever we have.
            }
            guard let self, self.session == current else { return }
            self.finish()
        }

        // Tap with `format: nil` so the tap always uses the input's *current* format. The format read
        // above can go stale during the awaits (e.g. Bluetooth headphones switching to their mic
        // profile), and tapping with a stale format raises an Objective-C exception. That exception
        // unwinds through Swift's task machinery and leaves the main thread in a corrupt state,
        // which crashed the app on the next mouse move.
        let converter = TapConverter(to: analyzerFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.reportLevel(of: buffer)
            if let converted = converter.convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }

        engine.prepare()
        try engine.start()

        analyzerTask = Task {
            try? await analyzer.start(inputSequence: stream)
        }
        state = .listening
        scheduleSilenceStop(after: 8)   // nothing said at all: stop after 8 seconds
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
        finalizedText = ""
        volatileText = ""
    }

    /// Turns the microphone off and removes the tap. Safe to call when it was never on.
    private func stopAudio() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Ends the session from any state without delivering anything.
    private func abort() {
        stopAudio()
        teardown()
        state = .idle
    }

    /// Ends the session and reports whatever was heard.
    private func finish() {
        guard state == .listening || state == .finalizing else { return }
        if state == .listening { stopAudio() }
        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        state = .idle
        onFinal?(text)
    }
}

/// Converts microphone buffers into the analyzer's format. Used only from the audio tap's thread.
/// Rebuilds its converter whenever the microphone's format changes.
private final class TapConverter {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to format: AVAudioFormat) {
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
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
}

private struct VoiceError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
