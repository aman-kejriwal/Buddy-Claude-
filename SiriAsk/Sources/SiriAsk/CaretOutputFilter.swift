import Foundation

/// Sits between Claude's streamed answer and the text cursor, so only the text the user asked
/// for gets typed. Everything else is held back:
///
/// - A reply that isn't text to insert ("NOTE: …" by instruction, or a refusal / "I don't
///   understand" / "could you clarify your request") is never typed: it becomes a short toast.
/// - Remarks from the assistant to the user are dropped: an opening "Here's a draft email:"
///   and lines like "Let me know if you'd like any changes" or "Feel free to adjust the tone".
///
/// Text is still typed live. Only the first few words of each line wait (about 24 characters)
/// to see whether the line is one of these; normal lines are then released straight away.
final class CaretOutputFilter {
    enum Ending {
        /// The rest of the text to type (may be empty).
        case text(String)
        /// Nothing should be typed: show this to the user instead.
        case note(String)
    }

    /// Prefix Claude is told to use when it can't write the text (see `CaretAssistant.systemPrompt`).
    static let notePrefix = "NOTE:"

    private enum Mode { case streaming, note, holdAll }
    private var mode = Mode.streaming
    private var pending = ""          // received but not yet released or dropped
    private var atLineStart = true
    private var isFirstLine = true

    /// How much of a line is seen before deciding it's ordinary text.
    private static let lookahead = 24

    /// Feeds a streamed piece; returns the text that can be typed now.
    func feed(_ text: String) -> String {
        pending += text
        return release(finishing: false)
    }

    /// The stream ended: returns what's left to type, or a note to show instead.
    func finish() -> Ending {
        var head = ""
        if mode == .streaming {
            // The last line may only now be judged (and may switch to note/holdAll).
            head = release(finishing: true)
            if mode == .streaming { return .text(head) }
        }
        switch mode {
        case .note:
            return .note(Self.shorten(Self.afterNotePrefix(pending)))
        case .holdAll:
            if Self.isRefusal(pending) { return .note(Self.shorten(pending)) }
            // A real text that happened to start like a refusal ("Sorry I missed your call…").
            mode = .streaming
            atLineStart = true
            isFirstLine = false
            return .text(head + release(finishing: true))
        case .streaming:
            return .text(head)
        }
    }

    // MARK: - Line by line

    private func release(finishing: Bool) -> String {
        guard mode == .streaming else { return "" }
        var out = ""
        while !pending.isEmpty {
            if !atLineStart {
                // Middle of a line already judged as normal text: release up to its end.
                if let nl = pending.firstIndex(of: "\n") {
                    out += pending[...nl]
                    pending.removeSubrange(...nl)
                    atLineStart = true
                } else {
                    out += pending
                    pending = ""
                }
                continue
            }

            // Blank lines and indentation pass through (the caller trims leading/trailing ones).
            if let first = pending.first, first.isWhitespace {
                out.append(first)
                pending.removeFirst()
                continue
            }

            let nl = pending.firstIndex(of: "\n")
            let line = String(nl.map { pending[..<$0] } ?? pending[...])
            let complete = nl != nil || finishing

            switch judge(line, complete: complete) {
            case .wait:
                return out
            case .keep:
                atLineStart = false
                isFirstLine = false
            case .drop:
                // Remove the line and its line break; keep going with the next one.
                if let nl { pending.removeSubrange(...nl) } else { pending = "" }
                isFirstLine = false
            case .note:
                mode = .note
                return out
            case .holdAll:
                mode = .holdAll
                return out
            }
        }
        return out
    }

    private enum Verdict { case wait, keep, drop, note, holdAll }

    private func judge(_ line: String, complete: Bool) -> Verdict {
        let t = line.trimmingCharacters(in: .whitespaces)
        let enough = complete || t.count >= Self.lookahead

        if isFirstLine {
            if t.uppercased().hasPrefix(Self.notePrefix) { return .note }
            if Self.notePrefix.hasPrefix(t.uppercased()) && !complete { return .wait }
            if !enough { return .wait }
            if Self.matches(t, Self.refusalStart) { return .holdAll }
            // "Microsoft doesn't publish a support email…": an answer about the request, not text
            // for the field. Needs the whole first sentence, so wait for it (short wait).
            guard let sentence = Self.firstSentence(t, complete: complete) else { return .wait }
            if Self.matches(sentence, Self.unavailable) { return .holdAll }
            if Self.matches(t, Self.preambleStart) {
                guard complete else { return .wait }
                return Self.matches(t, Self.preambleLine) ? .drop : .keep
            }
        } else if !enough {
            return .wait
        }

        if Self.matches(t, Self.chatterStart) {
            guard complete else { return .wait }   // need the whole line to be sure
            return Self.matches(t, Self.chatterLine) ? .drop : .keep
        }
        return .keep
    }

    // MARK: - Patterns (case-insensitive, on a trimmed line)

    /// Openers addressed to the user: "Here's a draft email:", "Sure! Here is the reply:".
    private static let preambleStart = #"^(here('s| is| are)|sure|certainly|of course|absolutely|okay|ok|got it)\b"#
    private static let preambleLine = #"^(here('s| is| are)|sure|certainly|of course|absolutely|okay|ok|got it)\b.{0,120}:$|^(sure|certainly|of course|absolutely|okay|ok|got it)[!.,]?$"#

    /// Lines that may be the assistant talking to the user (checked in full by `chatterLine`).
    private static let chatterStart = #"^(let me know|feel free|would you like|do you want|if you('d| would) like|if you want|if you need|i hope this|hope this|you can (adjust|edit|change|customi[sz]e|modify|tweak|replace|fill)|you may want|note:|\(note|i've (written|drafted|kept|added|included|made)|i have (written|drafted|kept|added|included|made)|this (draft|email|message|reply|version) )"#
    private static let chatterLine = #"(\b(changes?|adjust\w*|edit\w*|tweak\w*|modif\w*|revis\w*|draft|version|tone|longer|shorter|rewrite|rephrase|customi[sz]\w*|placeholders?|fill in|replac\w*|recipient's name|your name|anything else i can|further (help|assistance)|more help|any other help|help with anything else|assist (you )?further)\b|^i('ve| have) (written|drafted|kept|added|included|made)|^this (draft|email|message|reply|version) )"#

    /// How a refusal / "I don't follow" reply starts. The whole reply is held and checked.
    private static let refusalStart = #"^(i('m| am) sorry|sorry|apologies|unfortunately|i (can't|cannot|can not|couldn't|could not|won't|am unable|'m unable|am not able|'m not able|don't|do not|didn't|did not)\b|i('m| am) not (sure|able)|as an ai|could you (please )?(clarify|provide|share|tell|specify|explain)|can you (please )?(clarify|provide|share|tell|specify|explain)|please (clarify|specify|provide more)|what (would|do) you (like|want|mean)|i need (more|a bit more))"#
    /// Confirms a held reply is about the request, not a real message ("Sorry, I can't make it Friday").
    private static let refusalBody = #"(your request|this request|the request|clarif\w*|more (details|information|context)|what you('d| would) like( me)? to|what you mean|what you('re| are) (asking|looking)|as an ai|i('m| am) claude|i('m| am) an ai|i (can't|cannot|can not|won't|am unable to|'m unable to|'m not able to|am not able to) (help|assist|write|do|complete|create|generate|provide|fulfil+)|unable to (help|assist|write|complete|generate)|i (don't|do not|didn't|did not|couldn't|could not) (understand|follow)|not sure what you)"#

    /// "X doesn't publish an email", "there is no public number", "I don't have access to…":
    /// Claude explaining that what was asked for doesn't exist or isn't known.
    private static let unavailable = #"((doesn't|does not|don't|do not|didn't|did not|isn't|is not) (publicly |currently |officially )?(publish|provide|list|share|offer|have|maintain|disclose|make|available)\w*|there (is|'s|are) no|no (public|official|general|direct|dedicated|single) |i (don't|do not) (have|know) |i('m| am) not (aware|certain|sure) |i (couldn't|could not|can't|cannot) (find|verify|confirm|look|browse|access|check|know))"#
    private static let unavailableTopic = #"\b(e-?mail|address|phone|number|contact|url|link|website|site|page|id|information|details|data|access|real-time|current|up-to-date|that|this)\b"#

    private static func isRefusal(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 600 else { return false }
        if matches(t, refusalBody) { return true }
        guard let first = firstSentence(t, complete: true) else { return false }
        return matches(first, unavailable) && matches(first, unavailableTopic)
    }

    /// The first sentence of `line`, or nil if it hasn't finished streaming yet.
    private static func firstSentence(_ line: String, complete: Bool) -> String? {
        var prev: Character?
        for (i, ch) in line.enumerated() {
            if ch.isWhitespace, let p = prev, ".?!".contains(p) { return String(line.prefix(i)) }
            prev = ch
        }
        return complete || line.count >= 240 ? line : nil
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func afterNotePrefix(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= notePrefix.count ? String(t.dropFirst(notePrefix.count)) : t
    }

    /// One or two sentences, at most ~220 characters, on one line.
    static func shorten(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard flat.count > 220 else { return flat.isEmpty ? "Buddy couldn't write that." : flat }
        let cut = flat.prefix(220)
        // Cut after a sentence end (". " or the end), not at the dot in "support.microsoft.com".
        var end: String.Index?
        var i = cut.startIndex
        while i < cut.endIndex {
            let next = flat.index(after: i)
            if ".?!".contains(cut[i]), next == flat.endIndex || flat[next].isWhitespace { end = i }
            i = next
        }
        if let end, cut.distance(from: cut.startIndex, to: end) > 40 {
            return String(cut[...end])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}
