import AppKit
import Combine
import SwiftUI

/// Write at cursor: press the shortcut (⌥⇧Space) while the text cursor is in any app, a small
/// prompt opens right at the cursor, and Claude's answer is typed into that spot as it streams.
///
/// - Uses its own Claude Code process with a writing-only system prompt and no tools, so it
///   never touches the chat panel's conversation. It restarts after every write, so each
///   request starts with fresh context (and the restart is already warm by the next use).
/// - Text around the cursor (and any selection) is sent along as context; a selection is replaced.
/// - Writes only into the field the cursor was in: any key press or click, switching apps or
///   windows, or focus moving to another element stops it before the next insert.
final class CaretAssistant: NSObject, NSWindowDelegate {

    final class ViewModel: ObservableObject {
        @Published var prompt = ""
        @Published var contextLabel = ""
        @Published var status = ""
        @Published var isWriting = false
        @Published var isError = false
        /// The toast is a message from Claude (couldn't write it, needs more detail), not an error.
        @Published var isNote = false
        /// Bumped each time the prompt opens so the text field takes focus again.
        @Published var showCount = 0
        /// Bumped on every warning so the warning pops and shakes again, even if it is already shown.
        @Published var flashCount = 0
    }

    private let vm = ViewModel()
    private let session = ClaudeSession(extraArguments: [
        "--system-prompt", CaretAssistant.systemPrompt,
        "--strict-mcp-config",   // no MCP servers: faster start, nothing to call
        "--tools", "",           // no tools: it only writes text
    ])
    private let typer = CaretTyper()
    /// Keeps refusals, "I don't understand" replies and assistant remarks out of the user's text.
    private var outputFilter = CaretOutputFilter()

    private let promptPanel: CaretPromptPanel
    private let statusPanel: NSPanel
    private let promptHosting: NSHostingView<CaretPromptView>
    private let statusHosting: NSHostingView<CaretStatusView>

    private var context: CaretContext?
    private var isPrompting = false
    private var isWriting = false
    private var streamFinished = false
    private var typedAnything = false
    /// Whitespace held back until a visible character follows (trims leading/trailing blank lines).
    private var pendingWhitespace = ""

    private var cancelMonitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    private var statusHideWork: DispatchWorkItem?

    override init() {
        promptPanel = CaretPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        statusPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        promptHosting = NSHostingView(rootView: CaretPromptView(model: vm, onSubmit: {}, onCancel: {}))
        statusHosting = NSHostingView(rootView: CaretStatusView(model: vm))
        super.init()

        promptHosting.rootView = CaretPromptView(
            model: vm,
            onSubmit: { [weak self] in self?.submit() },
            onCancel: { [weak self] in self?.cancelPrompt() })

        for panel in [promptPanel, statusPanel] {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .popUpMenu
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        }
        promptPanel.contentView = promptHosting
        promptPanel.delegate = self
        promptPanel.onEscape = { [weak self] in self?.cancelPrompt() }
        statusPanel.contentView = statusHosting
        statusPanel.ignoresMouseEvents = true

        session.onText = { [weak self] text in self?.received(text) }
        session.onFinished = { [weak self] error in self?.turnFinished(error) }
        typer.onDrained = { [weak self] in
            guard let self, self.isWriting, self.streamFinished else { return }
            self.finishWriting()
        }
    }

    // MARK: - Shortcut

    /// The shortcut: opens the prompt at the cursor, or stops a write in progress.
    func trigger() {
        if isWriting { stopWriting(); return }
        if isPrompting { cancelPrompt(); return }

        guard CaretContext.isTrusted else {
            CaretContext.requestTrust()
            flash("Allow SiriAsk in System Settings › Privacy & Security › Accessibility, then try again.",
                  at: nil, seconds: 5)
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            flash("Click into a text field in another app first.", at: nil)
            return
        }
        guard var ctx = CaretContext.capture() else { return }
        if ctx.focusKind == .unknown {
            // Chrome/Electron build their accessibility tree on first request: ask once more.
            Thread.sleep(forTimeInterval: 0.25)
            ctx = CaretContext.capture() ?? ctx
        }
        if ctx.focusKind == .notText {
            flash("Put the text cursor in a text field first.", at: ctx.caretRect)
            return
        }
        if ctx.isSecure {
            flash("Buddy doesn't write into password fields.", at: ctx.caretRect)
            return
        }

        hideStatus()
        context = ctx
        vm.prompt = ""
        vm.contextLabel = Self.label(for: ctx)
        showPrompt(near: ctx.caretRect)

        // Warm up (or pick up a model change) while the user types the request.
        if session.model != ClaudeModel.saved {
            session.model = ClaudeModel.saved
            session.restart()
        } else {
            session.start()
        }
    }

    private static func label(for ctx: CaretContext) -> String {
        var parts = [ctx.appName]
        if !ctx.selectedText.isEmpty {
            parts.append("replaces the selected text")
        } else if ctx.focusKind == .unknown {
            parts.append("make sure the text cursor is in a text field")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Prompt

    private func showPrompt(near caret: NSRect?) {
        isPrompting = true
        promptHosting.layoutSubtreeIfNeeded()
        let size = promptHosting.fittingSize
        promptPanel.setFrame(Self.frame(size: size, near: caret, preferBelow: true), display: true)
        promptPanel.alphaValue = 0
        // A non-activating panel takes the keyboard without activating SiriAsk, so the
        // target app stays frontmost and its text cursor stays where it was.
        promptPanel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            promptPanel.animator().alphaValue = 1
        }
        vm.showCount += 1
    }

    private func hidePrompt() {
        isPrompting = false
        promptPanel.orderOut(nil)
    }

    private func cancelPrompt() {
        guard isPrompting else { return }
        hidePrompt()
        context?.app.activate()
        context = nil
    }

    /// Clicking anywhere else closes the prompt.
    func windowDidResignKey(_ notification: Notification) {
        if isPrompting { cancelPrompt() }
    }

    private func submit() {
        let request = vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPrompting, !request.isEmpty, let ctx = context else { return }
        hidePrompt()

        isWriting = true
        streamFinished = false
        typedAnything = false
        pendingWhitespace = ""
        outputFilter = CaretOutputFilter()
        vm.isWriting = true
        vm.isError = false
        vm.status = "Writing…"
        showStatus(near: ctx.caretRect)

        // Insert through Accessibility when the field allows it, otherwise by pasting.
        typer.begin(target: ctx.element)
        typer.isTargetStillValid = { Self.isStillAtCursor(ctx) }
        typer.onTargetLost = { [weak self] in
            guard let self, self.isWriting else { return }
            self.stopWriting()
            self.flash("Stopped: the text cursor moved out of the field.", at: ctx.caretRect)
        }
        installCancelMonitors(targetPID: ctx.app.processIdentifier)
        // Give the keyboard back to the target app before the first insert.
        typer.isHeld = true
        ctx.app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isWriting else { return }
            self.typer.isHeld = false
        }

        if let error = session.send(Self.message(request: request, context: ctx)) {
            fail(error)
        }
    }

    // MARK: - Streaming into the cursor

    private func received(_ text: String) {
        guard isWriting else { return }
        type(outputFilter.feed(text))
    }

    /// Types filtered text, holding whitespace back so the output never starts or ends with it.
    private func type(_ text: String) {
        guard !text.isEmpty else { return }
        var out = ""
        for ch in text {
            if ch.isWhitespace {
                pendingWhitespace.append(ch)
            } else {
                if typedAnything || !out.isEmpty { out += pendingWhitespace }
                pendingWhitespace = ""
                out.append(ch)
            }
        }
        guard !out.isEmpty else { return }
        typedAnything = true
        typer.enqueue(out)
    }

    private func turnFinished(_ error: String?) {
        // Fresh context for the next write; restarting now means it's warm by then.
        DispatchQueue.main.async { [weak self] in self?.session.restart() }
        guard isWriting else { return }
        streamFinished = true
        if let error {
            fail(error)
            return
        }
        switch outputFilter.finish() {
        case .note(let message):
            // Not text for the field: show it instead (nothing was typed).
            showNote(message)
            return
        case .text(let rest):
            type(rest)
        }
        if !typedAnything {
            fail("Claude didn't write anything.")
        } else if typer.isIdle && !typer.isHeld {
            finishWriting()
        }
    }

    private func finishWriting() {
        isWriting = false
        vm.isWriting = false
        removeCancelMonitors()
        context = nil
        hideStatus()
    }

    /// Esc / click / app switch / shortcut again: stop typing and abandon the answer.
    private func stopWriting() {
        guard isWriting else { return }
        typer.cancel()
        if !streamFinished { session.restart() }   // abandons the turn in flight
        finishWriting()
    }

    /// Claude's reply wasn't text to insert ("I need to know who this is for…"): show it as a toast.
    private func showNote(_ message: String) {
        typer.cancel()
        let caret = context?.caretRect
        finishWriting()
        flash(message, at: caret, seconds: 6, isNote: true)
    }

    private func fail(_ message: String) {
        typer.cancel()
        let caret = context?.caretRect
        finishWriting()
        flash(message, at: caret)
    }

    /// Checked before every insert: same app in front, same front window, and (when the app
    /// reports it) the same focused element as when the prompt opened.
    private static func isStillAtCursor(_ ctx: CaretContext) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ctx.app.processIdentifier else { return false }
        if let original = ctx.window, let now = CaretContext.focusedWindow(in: ctx.app), !CFEqual(original, now) {
            return false
        }
        if let original = ctx.element, let now = CaretContext.focusedElement(in: ctx.app), !CFEqual(original, now) {
            return false
        }
        return true
    }

    private func installCancelMonitors(targetPID: pid_t) {
        removeCancelMonitors()
        // Any key the user presses (Esc, Tab, arrows, shortcuts…) stops writing: it may move the
        // cursor or focus. SiriAsk's own ⌘V events are tagged and ignored.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == CaretTyper.syntheticEventTag { return }
            self?.stopWriting()
        }) { cancelMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.stopWriting()   // a click moves the cursor; don't keep typing somewhere else
        }) { cancelMonitors.append(m) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != targetPID { self?.stopWriting() }
        }
    }

    private func removeCancelMonitors() {
        cancelMonitors.forEach { NSEvent.removeMonitor($0) }
        cancelMonitors.removeAll()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    // MARK: - Status pill

    private func showStatus(near caret: NSRect?) {
        statusHideWork?.cancel()
        statusHosting.layoutSubtreeIfNeeded()
        let size = statusHosting.fittingSize
        statusPanel.setFrame(Self.frame(size: size, near: caret, preferBelow: false), display: true)
        statusPanel.orderFrontRegardless()
    }

    private func hideStatus() {
        statusHideWork?.cancel()
        statusPanel.orderOut(nil)
    }

    /// Shows a short message near the cursor (or the pointer), then hides it.
    private func flash(_ message: String, at caret: NSRect?, seconds: Double = 4, isNote: Bool = false) {
        vm.isWriting = false
        vm.isError = true
        vm.isNote = isNote
        vm.status = message
        vm.flashCount += 1
        showStatus(near: caret)
        let work = DispatchWorkItem { [weak self] in self?.statusPanel.orderOut(nil) }
        statusHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - Placement

    /// Places a window of `size` next to the caret, kept on screen. The prompt goes below the
    /// line (like autocomplete); the status pill goes above it so it never covers new text.
    private static func frame(size: NSSize, near caret: NSRect?, preferBelow: Bool) -> NSRect {
        let anchor = caret ?? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 18))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let gap: CGFloat = 6

        let below = anchor.minY - gap - size.height
        let above = anchor.maxY + gap
        var y: CGFloat
        if preferBelow {
            y = below >= visible.minY ? below : above
        } else {
            y = above + size.height <= visible.maxY ? above : below
        }
        y = min(max(y, visible.minY), visible.maxY - size.height)

        var x = anchor.minX - 14
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Prompt text sent to Claude

    static let systemPrompt = """
    You write text that is typed directly at the user's text cursor in whatever macOS app they \
    are using (email, documents, chat, forms, notes, code editors, and so on).

    Output ONLY the exact text to insert at the cursor:
    - No preamble, no explanation, no closing remarks, no quotation marks around it.
    - Plain text only: no Markdown (no **, #, backticks or code fences). Use plain "-" for a list \
    only if a list is clearly wanted. In a code editor, output just the code.
    - Fit the app and the surrounding text: match its language, tone and format. An email gets \
    a greeting and sign-off when one isn't already there; a chat message stays short; a form field \
    gets just the value.
    - Continue naturally from the text before the cursor and never repeat it. If text is selected, \
    output the full replacement for the selection.
    - If the request is a question, write the answer as text to insert, but only the answer \
    itself, nothing around it.
    - Never talk to the user. No "Here's your email:", no "Let me know if you'd like changes", \
    no "I hope this helps", no notes about placeholders or tone. Lines meant for the reader of the \
    text (for example the email's recipient) are fine.

    - If you can't generate the output for the question asked by any reason then you must respond with a NOTE:
    followed by a brief explanation, and do not write any other text.
    """

    static func message(request: String, context ctx: CaretContext) -> String {
        var parts: [String] = []
        var where_ = "App: \(ctx.appName)"
        if let title = ctx.windowTitle, !title.isEmpty { where_ += " — window: \"\(title)\"" }
        parts.append(where_)
        if !ctx.textBefore.isEmpty {
            parts.append("Text before the cursor (already written; don't repeat it):\n<before>\n\(ctx.textBefore)\n</before>")
        }
        if !ctx.textAfter.isEmpty {
            parts.append("Text after the cursor:\n<after>\n\(ctx.textAfter)\n</after>")
        }
        if !ctx.selectedText.isEmpty {
            parts.append("Selected text (your output replaces it):\n<selected>\n\(ctx.selectedText)\n</selected>")
        }
        parts.append("Request: \(request)")
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Windows

/// The prompt window. Borderless + non-activating, so it can take typing without pulling
/// focus away from the app being written into.
final class CaretPromptPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// SiriAsk isn't the active app while this is open, so its Edit menu doesn't see ⌘V/⌘C/…
    /// Route the usual editing shortcuts to the text field directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command || mods == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() {
            var action: Selector?
            switch key {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = mods.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            default: break
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct CaretGlass: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(
                Color.clear
                    .glassEffect(.regular.tint(Color.black.opacity(0.3)), in: shape)
                    .clipShape(shape)
            )
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7).allowsHitTesting(false))
    }
}

struct CaretPromptView: View {
    @ObservedObject var model: CaretAssistant.ViewModel
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                OrbView(active: false)
                    .frame(width: 30, height: 30)
                TextField("What should Buddy write here?", text: $model.prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, design: .rounded))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit(onSubmit)
                Image(systemName: "return")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(model.prompt.isEmpty ? 0.25 : 0.7))
            }
            if !model.contextLabel.isEmpty {
                Text(model.contextLabel)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 460, alignment: .leading)
        .modifier(CaretGlass(radius: 18))
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
        .onChange(of: model.showCount) { _ in focused = true }
        .onExitCommand(perform: onCancel)
    }
}

struct CaretStatusView: View {
    @ObservedObject var model: CaretAssistant.ViewModel

    var body: some View {
        if model.isError {
            CaretWarningView(message: model.status, trigger: model.flashCount, isNote: model.isNote)
        } else {
            writingPill
        }
    }

    private var writingPill: some View {
        HStack(spacing: 8) {
            OrbView(active: model.isWriting)
                .frame(width: 30, height: 30)
                .scaleEffect(0.7)
                .frame(width: 22, height: 22)
            Text(model.status)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            if model.isWriting {
                Text("esc to stop")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .fixedSize()
        .modifier(CaretGlass(radius: 14))
        .environment(\.colorScheme, .dark)
    }
}

/// A warning that has to stand out on any background (light pages, dark pages, busy
/// wallpapers): a solid amber card with a white border and a glow, which pops in and shakes.
private struct CaretWarningView: View {
    let message: String
    let trigger: Int
    /// A message from Claude rather than a warning: blue-violet, speech-bubble icon.
    var isNote = false

    private static let amber = Color(red: 1.0, green: 0.62, blue: 0.10)
    private static let amberDeep = Color(red: 0.93, green: 0.40, blue: 0.05)
    private static let blue = Color(red: 0.16, green: 0.42, blue: 0.95)
    private static let violet = Color(red: 0.45, green: 0.25, blue: 0.88)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: isNote ? "text.bubble.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(shape.fill(LinearGradient(colors: isNote ? [Self.blue, Self.violet] : [Self.amber, Self.amberDeep],
                                              startPoint: .top, endPoint: .bottom)))
        .overlay(shape.strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
        // Dark shadow lifts it off light backgrounds; the amber glow shows on dark ones.
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .shadow(color: (isNote ? Self.blue : Self.amber).opacity(0.8), radius: 14)
        .keyframeAnimator(initialValue: WarningMotion(), trigger: trigger) { content, m in
            content.scaleEffect(m.scale).offset(x: m.shake)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.08, duration: 0.15)
                SpringKeyframe(1.0, duration: 0.25)
            }
            KeyframeTrack(\.shake) {
                LinearKeyframe(0, duration: 0.15)
                CubicKeyframe(-7, duration: 0.06)
                CubicKeyframe(7, duration: 0.08)
                CubicKeyframe(-5, duration: 0.08)
                CubicKeyframe(4, duration: 0.07)
                CubicKeyframe(0, duration: 0.06)
            }
        }
        .padding(24)   // room for the glow, shake and pop inside the window
        .fixedSize()
    }
}

private struct WarningMotion {
    var scale: CGFloat = 1
    var shake: CGFloat = 0
}
