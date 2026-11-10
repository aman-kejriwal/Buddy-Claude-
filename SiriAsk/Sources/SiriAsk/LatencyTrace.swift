import Foundation

/// Records when each stage of one question happens and logs a breakdown when the answer starts playing
/// (or, for typed questions, when the answer finishes).
///
/// Log file: ~/Library/Logs/SiriAsk/latency.log  (also printed with NSLog, visible in Console.app).
final class LatencyTrace {

    enum Mark: String, CaseIterable {
        case listenStart     = "mic opened"
        case firstWord       = "first word recognized"
        case lastWord        = "last word recognized"
        case transcriptFinal = "transcript final (silence wait over)"
        case sent            = "question sent to Claude"
        case firstEvent      = "Claude: first stdout event"
        case firstToken      = "Claude: first text token"
        case lastToken       = "Claude: last text token"
        case resultReceived  = "Claude: turn finished"
        case speakCalled     = "TTS request started"
        case audioStarted    = "audio playing"
    }

    private var times: [Mark: Date] = [:]
    private var notes: [String] = []
    private(set) var isActive = false

    /// Starts a new trace, throwing away the previous one.
    func begin(at mark: Mark) {
        times = [mark: Date()]
        notes = []
        isActive = true
    }

    /// Records a mark the first time it happens. `lastWord` and `lastToken` keep the latest time.
    func mark(_ mark: Mark) {
        guard isActive else { return }
        if mark == .lastWord || mark == .lastToken || times[mark] == nil {
            times[mark] = Date()
        }
    }

    func note(_ text: String) {
        guard isActive else { return }
        notes.append(text)
    }

    /// Writes the breakdown and ends the trace.
    func finish(_ question: String) {
        guard isActive else { return }
        isActive = false
        let report = Self.format(times: times, notes: notes, question: question)
        NSLog("SiriAsk latency\n%@", report)
        Self.append(report)
    }

    private static func format(times: [Mark: Date], notes: [String], question: String) -> String {
        guard let origin = Mark.allCases.compactMap({ times[$0] }).min() else { return "" }
        func ms(_ m: Mark) -> Int? { times[m].map { Int($0.timeIntervalSince(origin) * 1000) } }
        func span(_ a: Mark, _ b: Mark) -> Int? {
            guard let ta = times[a], let tb = times[b] else { return nil }
            return Int(tb.timeIntervalSince(ta) * 1000)
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = ["=== \(stamp)  \"\(question.prefix(60))\""]

        lines.append("  Timeline (ms since start):")
        for m in Mark.allCases {
            if let v = ms(m) { lines.append(String(format: "    %6d  %@", v, m.rawValue)) }
        }

        // The stages, in the order the user waits for them.
        let stages: [(String, Int?)] = [
            ("speaking (first→last word)", span(.firstWord, .lastWord)),
            ("silence wait + finalize", span(.lastWord, .transcriptFinal)),
            ("hand-off to Claude", span(.transcriptFinal, .sent)),
            ("Claude time to first token", span(.sent, .firstToken)),
            ("Claude streaming the rest", span(.firstToken, .lastToken)),
            ("Claude turn wrap-up", span(.lastToken, .resultReceived)),
            ("wait before TTS starts", span(.resultReceived, .speakCalled)),
            ("TTS time to first audio", span(.speakCalled, .audioStarted)),
        ]
        lines.append("  Stages:")
        for (name, value) in stages {
            if let value { lines.append(String(format: "    %6d ms  %@", value, name)) }
        }

        // What the user actually waits through: from the moment they stop talking (or hit return).
        let start: Mark = times[.lastWord] != nil ? .lastWord : .sent
        let end: Mark = times[.audioStarted] != nil ? .audioStarted : .resultReceived
        if let total = span(start, end) {
            lines.append(String(format: "  ⇒ %d ms from %@ to %@", total,
                                start == .lastWord ? "end of speech" : "send", end == .audioStarted ? "first audio" : "full answer"))
        }
        if let ttfText = span(start, .firstToken) {
            lines.append(String(format: "  ⇒ %d ms until first answer text appears in the panel", ttfText))
        }
        for note in notes { lines.append("  note: \(note)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func append(_ text: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SiriAsk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("latency.log")
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
