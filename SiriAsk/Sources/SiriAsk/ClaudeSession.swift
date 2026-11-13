import Foundation

/// The Claude models the user can pick from the menu bar.
enum ClaudeModel: String, CaseIterable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"

    var displayName: String {
        switch self {
        case .haiku: return "Haiku 5.5"
        case .sonnet: return "Sonnet 5.5"
        case .opus: return "Opus 5.5"
        }
    }

    var detail: String {
        switch self {
        case .haiku: return "Fastest"
        case .sonnet: return "Balanced"
        case .opus: return "Most capable"
        }
    }

    private static let defaultsKey = "SiriAsk.model"

    /// The saved choice, or Haiku (fast answers) if nothing was picked yet.
    static var saved: ClaudeModel {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(ClaudeModel.init(rawValue:)) ?? .haiku
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

/// One long-lived Claude Code process, talking over stream-json.
///
/// - Started once (at app launch), so questions don't pay the startup cost.
/// - Each question is a line on stdin; answers stream back as text deltas on stdout.
/// - Context carries over between questions for as long as the process lives.
///
/// Settings safety:
/// - Only runs `claude` in print/stream mode. Never passes `--settings`, never writes to `~/.claude`.
/// - `--no-session-persistence` means no transcript files are saved.
final class ClaudeSession {

    /// The model used the next time the process launches. Change it, then call `restart()`.
    var model: ClaudeModel = .saved

    /// Called on the main queue with each streamed piece of text.
    var onText: ((String) -> Void)?
    /// Called on the main queue when a turn ends. `nil` means success; otherwise the error message.
    var onFinished: ((String?) -> Void)?
    /// Called on the main queue for every stdout event (used for latency timing).
    var onAnyEvent: (() -> Void)?
    /// Called on the main queue with timing/usage numbers Claude Code reports at the end of a turn.
    var onTurnStats: ((String) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var turnActive = false

    private static let candidatePaths: [String] = [
        NSHomeDirectory() + "/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    init() {
        // Writing to a process that has exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    /// Starts the background process if it isn't already running.
    func start() {
        guard !isRunning else { return }
        launch()
    }

    /// Sends one question. Returns an error message if it couldn't be sent, otherwise nil.
    @discardableResult
    func send(_ text: String) -> String? {
        // One turn at a time: a second message would be answered after the first, and the
        // first turn's "result" would end the second turn early.
        guard !turnActive else { return "Still answering the last question." }
        if !isRunning { launch() }
        guard isRunning, let stdin else {
            return "Couldn't start Claude Code. Check that `claude` is installed."
        }

        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            return "Couldn't encode the question."
        }

        turnActive = true
        do {
            try stdin.write(contentsOf: data + Data([0x0A]))
            return nil
        } catch {
            turnActive = false
            return "Lost connection to Claude Code. Ask again to restart it."
        }
    }

    /// Ends the process, which clears the conversation context.
    func restart() {
        stop()
        launch()
    }

    func stop() {
        try? stdin?.close()
        if isRunning { process?.terminate() }
        process = nil
        stdin = nil
        turnActive = false
        buffer.removeAll()
    }

    // MARK: - Launching

    private func binaryPath() -> String? {
        let fm = FileManager.default
        if let found = Self.candidatePaths.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return found
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in pathDirs {
            let candidate = "\(dir)/claude"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func launch() {
        guard let binary = binaryPath() else {
            reportFailure("Couldn't find the `claude` command. Install Claude Code or check its path.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model.rawValue,
            "--no-session-persistence",
        ]
        // Run from home so no project-specific CLAUDE.md is pulled in by accident.
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        // Use the normal Claude Code login, the same as the user's shell alias.
        var env = ProcessInfo.processInfo.environment
        env["ANTHROPIC_API_KEY"] = nil
        env["ANTHROPIC_AUTH_TOKEN"] = nil
        process.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.consume(data, from: process) }
        }
        // Drain stderr so the process never blocks on a full pipe.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.processEnded(proc) }
        }

        do {
            try process.run()
            self.process = process
            self.stdin = inPipe.fileHandleForWriting
            self.buffer.removeAll()
        } catch {
            reportFailure("Couldn't start Claude Code: \(error.localizedDescription)")
        }
    }

    private func processEnded(_ proc: Process) {
        // Ignore exits from a process we've already replaced.
        guard proc === process else { return }
        process = nil
        stdin = nil
        if turnActive {
            turnActive = false
            onFinished?("Claude Code stopped. Ask again to restart it.")
        }
    }

    private func reportFailure(_ message: String) {
        turnActive = false
        DispatchQueue.main.async { [weak self] in
            self?.onFinished?(message)
        }
    }

    // MARK: - Parsing stdout (one JSON object per line)

    private func consume(_ data: Data, from proc: Process) {
        guard proc === process else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            handleLine(line)
        }
    }

    private func handleLine(_ line: Data) {
        guard
            !line.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String
        else { return }

        if turnActive { onAnyEvent?() }

        switch type {
        case "stream_event":
            // Streamed answer text arrives as text_delta events. Thinking deltas are ignored.
            guard
                let event = object["event"] as? [String: Any],
                event["type"] as? String == "content_block_delta",
                let delta = event["delta"] as? [String: Any],
                delta["type"] as? String == "text_delta",
                let text = delta["text"] as? String
            else { return }
            onText?(text)

        case "result":
            guard turnActive else { return }
            turnActive = false
            let usage = object["usage"] as? [String: Any] ?? [:]
            func n(_ v: Any?) -> String { (v as? NSNumber)?.stringValue ?? "?" }
            onTurnStats?("Claude Code: duration_ms=\(n(object["duration_ms"])) api_ms=\(n(object["duration_api_ms"])) "
                + "input=\(n(usage["input_tokens"])) cache_read=\(n(usage["cache_read_input_tokens"])) "
                + "cache_write=\(n(usage["cache_creation_input_tokens"])) output=\(n(usage["output_tokens"])) model=\(model.rawValue)")
            if object["is_error"] as? Bool == true {
                let message = (object["result"] as? String) ?? "Claude returned an error."
                onFinished?(message)
            } else {
                onFinished?(nil)
            }

        default:
            break
        }
    }
}
