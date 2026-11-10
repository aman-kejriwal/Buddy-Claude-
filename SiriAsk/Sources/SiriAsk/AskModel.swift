import Foundation
import Combine

/// The state behind the Siri-style panel.
/// The last question and answer stay visible when the panel is reopened, and the
/// Claude session keeps context until "New Conversation" or quit.
final class AskModel: ObservableObject {

    enum Phase: Equatable {
        case idle        // nothing asked yet in this conversation
        case thinking    // question sent, no text yet
        case streaming   // answer text is arriving
        case done        // answer complete
        case failed      // error shown in place of the answer
    }

    @Published var query: String = ""
    @Published private(set) var question: String = ""
    @Published private(set) var response: String = ""
    @Published private(set) var errorMessage: String = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isListening = false
    /// Current microphone loudness, used to animate the listening waveform.
    @Published private(set) var audioLevel: Float = 0
    /// Increments each time the panel opens, so the text field can take focus again.
    @Published private(set) var showCount = 0

    /// True when the current question was spoken, so its answer is read aloud.
    /// Typed questions get text answers only.
    private var askedByVoice = false

    /// Set by the panel controller. Voice input and spoken replies only run while the panel is on screen.
    /// Published so the panel's animations pause (and stop using CPU) while it is hidden.
    @Published var isPanelVisible = false

    private let session = ClaudeSession()
    private let voiceInput = VoiceInput()
    private let voiceOutput = VoiceOutput()
    /// Per-question timing, written to ~/Library/Logs/SiriAsk/latency.log.
    private let trace = LatencyTrace()

    init() {
        session.onAnyEvent = { [weak self] in self?.trace.mark(.firstEvent) }
        session.onTurnStats = { [weak self] stats in self?.trace.note(stats) }
        voiceOutput.onAudioStarted = { [weak self] voice in
            guard let self else { return }
            self.trace.mark(.audioStarted)
            self.trace.note("voice: \(voice)")
            self.trace.finish(self.question)
        }
        session.onText = { [weak self] text in
            guard let self else { return }
            self.trace.mark(.firstToken)
            self.trace.mark(.lastToken)
            self.response += text
            if self.phase == .thinking { self.phase = .streaming }
        }
        session.onFinished = { [weak self] error in
            guard let self else { return }
            self.trace.mark(.resultReceived)
            if let error {
                self.errorMessage = error
                self.phase = .failed
                self.trace.note("error: \(error)")
                self.trace.finish(self.question)
            } else {
                self.phase = .done
                if self.askedByVoice && self.isPanelVisible {
                    self.trace.mark(.speakCalled)
                    self.voiceOutput.speak(Self.spokenText(for: self.response))
                } else {
                    self.trace.finish(self.question)
                }
            }
        }

        voiceInput.onPartial = { [weak self] text in
            guard let self else { return }
            if !text.isEmpty, text != self.query {
                self.trace.mark(.firstWord)
                self.trace.mark(.lastWord)
            }
            self.query = text
        }
        voiceInput.onLevel = { [weak self] level in
            self?.audioLevel = level
        }
        voiceInput.onFinal = { [weak self] text in
            guard let self else { return }
            self.isListening = false
            self.audioLevel = 0
            self.trace.mark(.transcriptFinal)
            if !text.isEmpty {
                self.query = text
                self.submit(byVoice: true)
            }
        }
        voiceInput.onError = { [weak self] message in
            guard let self else { return }
            self.isListening = false
            self.audioLevel = 0
            self.question = ""
            self.response = ""
            self.errorMessage = message
            self.phase = .failed
        }
    }

    /// Starts Claude Code in the background so the first question is already fast.
    func warmUp() {
        session.start()
    }

    func didShow() {
        showCount += 1
    }

    func submit(byVoice: Bool = false) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase != .thinking else { return }

        voiceOutput.stop()
        askedByVoice = byVoice
        question = text
        query = ""
        response = ""
        errorMessage = ""
        phase = .thinking

        if !byVoice { trace.begin(at: .sent) } else { trace.mark(.sent) }
        if !session.isRunning { trace.note("Claude Code was not running; this question paid the startup cost") }
        if let error = session.send(text) {
            errorMessage = error
            phase = .failed
        }
    }

    /// Starts listening if it isn't already (used by the fn-key shortcut). Never stops it.
    func startListening() {
        guard isPanelVisible, !voiceInput.isListening else { return }
        voiceOutput.stop()
        isListening = true
        trace.begin(at: .listenStart)
        voiceInput.start()
    }

    /// Click the microphone to start speaking; click again to stop and send.
    func toggleListening() {
        guard isPanelVisible || voiceInput.isListening else { return }
        voiceOutput.stop()
        if voiceInput.isListening {
            voiceInput.stop()
        } else {
            isListening = true
            trace.begin(at: .listenStart)
            voiceInput.start()
        }
    }

    /// Called when the panel is hidden: stop the microphone and any speech, and discard unsent speech.
    func panelHidden() {
        isPanelVisible = false
        voiceInput.cancel()
        isListening = false
        audioLevel = 0
        voiceOutput.stop()
    }

    /// The Claude model answering questions.
    var selectedModel: ClaudeModel { session.model }

    /// Switches model. Claude Code picks its model at launch, so this restarts it
    /// and starts a new conversation.
    func setModel(_ newModel: ClaudeModel) {
        guard newModel != session.model else { return }
        ClaudeModel.saved = newModel
        session.model = newModel
        newConversation()
    }

    /// Forgets the conversation: clears the panel and restarts Claude Code with no context.
    func newConversation() {
        voiceOutput.stop()
        session.restart()
        query = ""
        question = ""
        response = ""
        errorMessage = ""
        phase = .idle
    }

    func shutdown() {
        voiceOutput.stop()
        voiceInput.stop()
        session.stop()
    }

    /// The part of an answer that is worth saying out loud. Code is replaced by a short note.
    static func spokenText(for response: String) -> String {
        AnswerSegment.parse(response).map { segment -> String in
            switch segment.kind {
            case .code:
                return "The code is in the panel."
            case .text:
                return segment.body
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .replacingOccurrences(of: "#", with: "")
            }
        }
        .joined(separator: " ")
    }
}
