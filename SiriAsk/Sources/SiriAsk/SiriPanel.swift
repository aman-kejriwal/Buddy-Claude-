import AppKit
import Combine
import SwiftUI

// MARK: - Palette (Siri-inspired multicolour)

let siriColors: [Color] = [
    Color(red: 0.25, green: 0.82, blue: 1.00), // cyan
    Color(red: 0.30, green: 0.42, blue: 1.00), // blue
    Color(red: 0.71, green: 0.36, blue: 1.00), // violet
    Color(red: 1.00, green: 0.31, blue: 0.63), // pink
    Color(red: 1.00, green: 0.64, blue: 0.23), // orange
    Color(red: 0.25, green: 0.82, blue: 1.00), // cyan (loop seam)
]

// MARK: - Floating panel

final class SiriPanel: NSPanel {
    // Borderless panels can't take keyboard focus unless we allow it.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Runs when Esc is pressed and nothing in the panel handled it (e.g. in voice mode, when there is no text field).
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Hosting view. Dragging is handled by SwiftUI (see `SiriRootView`), so AppKit's own
/// window-drag is switched off to avoid moving the window twice.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Owns the floating window: positioning, show/hide, dragging, and fitting its height to the content.
final class SiriPanelController: NSObject, NSWindowDelegate {
    private let model: AskModel
    private let panel: SiriPanel
    private let hosting: DraggableHostingView<SiriRootView>
    private var cancellables = Set<AnyCancellable>()

    private let panelWidth: CGFloat = 640
    private let bottomInset: CGFloat = 90
    private let minHeight: CGFloat = 80
    private(set) var isVisible = false

    /// Remembered top-left corner, so the panel reopens where the user last put it.
    private static let positionKey = "SiriAsk.panelTopLeft"

    init(model: AskModel) {
        self.model = model
        panel = SiriPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 150),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        hosting = DraggableHostingView(rootView: SiriRootView(
            model: model,
            onDismiss: { },
            onDragBegan: { },
            onDragEnded: { }
        ))
        super.init()

        hosting.rootView = SiriRootView(
            model: model,
            onDismiss: { [weak self] in self?.hide() },
            onDragBegan: { [weak self] in self?.dragBegan() },
            onDragEnded: { [weak self] in self?.dragEnded() }
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // no window shadow: it shows as a dark halo around the glass
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // NSPanel hides itself whenever the app loses focus (e.g. a click on the menu bar).
        // Turn that off: hiding is decided in windowDidResignKey and the outside-click monitor.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = hosting
        panel.onEscape = { [weak self] in self?.hide() }

        // Whenever the conversation changes, resize the window to fit the new content.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fitToContent() }
            .store(in: &cancellables)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// Opens the panel and starts listening right away (the fn-key shortcut).
    func showInVoiceMode() {
        show()
        model.startListening()
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true
        model.isPanelVisible = true

        let height = contentHeight()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main

        // Reopen where the user last dragged it, if that spot is still on a screen.
        var placed = false
        if let top = savedTopLeft() {
            let saved = NSRect(x: top.x, y: top.y - height, width: panelWidth, height: height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
                panel.setFrame(saved, display: true)
                placed = true
            }
        }
        if !placed, let visible = screen?.visibleFrame {
            panel.setFrame(
                NSRect(x: visible.midX - panelWidth / 2,
                       y: visible.minY + bottomInset,
                       width: panelWidth,
                       height: height),
                display: true
            )
        }

        // Fade the whole window in (keeps Liquid Glass live; a SwiftUI fade would turn it black).
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        NSApp.activate(ignoringOtherApps: true)
        model.didShow()
        fitToContent()
    }

    func hide(reason: String = "toggle/esc") {
        guard isVisible else { return }
        isVisible = false
        stopWatchingForOutsideClick()
        model.panelHidden()   // stop listening and speaking while the panel is off screen
        panel.orderOut(nil)   // the conversation is kept; reopening shows it again
    }

    // MARK: Dismissing

    /// Watches for clicks in other apps while the panel is open but not focused.
    private var outsideClickMonitor: Any?

    /// Clicking anywhere outside the panel dismisses it, like Siri, except the menu bar:
    /// pointing at or clicking the menu bar (or its icons) leaves the panel open.
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        if isMouseInMenuBar() {
            watchForOutsideClick()
        } else {
            hide(reason: "resignKey")
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        stopWatchingForOutsideClick()
    }

    /// The panel stays up after the menu bar took focus; the next click elsewhere closes it.
    private func watchForOutsideClick() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.isVisible, !self.panel.isKeyWindow else { return }
            if !self.isMouseInMenuBar() && !self.panel.frame.contains(NSEvent.mouseLocation) {
                self.hide(reason: "outsideClick")
            }
        }
    }

    private func stopWatchingForOutsideClick() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    /// True when the pointer is in the menu-bar strip at the top of whichever screen it is on.
    /// Works with an auto-hiding menu bar too (the strip is then measured as at least 30 pt).
    private func isMouseInMenuBar() -> Bool {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else {
            return false
        }
        let barHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 30)
        return mouse.y >= screen.frame.maxY - barHeight
    }

    // MARK: Dragging

    // While dragging, follow the mouse's screen position directly. (SwiftUI's own drag
    // values are measured relative to the window, which moves, so they lag behind the mouse.)
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var dragMonitor: Any?

    private func dragBegan() {
        guard dragMonitor == nil else { return }
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = panel.frame.origin
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleDrag(event)
            return event
        }
    }

    private func handleDrag(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            dragEnded()
            return
        }
        guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: startOrigin.x + mouse.x - startMouse.x,
                                     y: startOrigin.y + mouse.y - startMouse.y))
    }

    private func dragEnded() {
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
        }
        dragMonitor = nil
        dragStartMouse = nil
        dragStartOrigin = nil
    }

    func windowDidMove(_ notification: Notification) {
        let topLeft = [Double(panel.frame.minX), Double(panel.frame.maxY)]
        UserDefaults.standard.set(topLeft, forKey: Self.positionKey)
    }

    // MARK: Sizing

    private func savedTopLeft() -> NSPoint? {
        guard let values = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double],
              values.count == 2 else { return nil }
        return NSPoint(x: values[0], y: values[1])
    }

    /// The height SwiftUI wants for the current content.
    private func contentHeight() -> CGFloat {
        max(hosting.fittingSize.height.rounded(.up), minHeight)
    }

    private func fitToContent() {
        guard isVisible else { return }
        resize(toHeight: contentHeight())
    }

    /// Keeps the top edge fixed (the question row stays where the user put it) and grows downward,
    /// but never below the bottom of the screen.
    private func resize(toHeight newHeight: CGFloat) {
        var frame = panel.frame
        guard abs(frame.height - newHeight) > 0.5 else { return }

        var newY = frame.maxY - newHeight
        if let visible = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })?.visibleFrame,
           newY < visible.minY {
            newY = visible.minY
        }
        frame.origin.y = newY
        frame.size.height = newHeight
        panel.setFrame(frame, display: true, animate: false)
    }
}

// MARK: - SwiftUI

/// Measures how tall a block of answer text will be at the panel's text width.
enum AnswerMeasure {
    static func height(for text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 20 }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .paragraphStyle: style,
        ]
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(rect.height)
    }
}

struct SiriRootView: View {
    @ObservedObject var model: AskModel
    let onDismiss: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// visionOS-style tilt: the card leans toward the cursor (degrees around each axis).
    @State private var tilt: CGSize = .zero
    /// 0 = folded back in depth (before the pop-in), 1 = resting flat in front of the screen.
    @State private var popIn: CGFloat = 0

    private let maxTilt: Double = 5
    private let cardPadding: CGFloat = 10            // just enough room for the hover lift

    private let cardRadius: CGFloat = 26
    private let answerWidth: CGFloat = 540          // card 584 minus 22 pt padding on each side
    private let maxAnswerHeight: CGFloat = 520      // longer answers scroll inside this height

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            inputRow
            if model.isListening && !model.query.isEmpty {
                // What has been recognised so far, shown while you speak.
                Text(model.query)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.phase != .idle {
                responseArea
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(width: 584, alignment: .leading)
        .background(
            // Dragging the empty card moves the window. Text, the input field and buttons
            // are in front of this background, so they keep their own clicks and drags.
            glassCard.simultaneousGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { _ in onDragBegan() }
                    .onEnded { _ in onDragEnded() }
            )
        )
        .overlay(cardEdge.allowsHitTesting(false))
        // No drop shadow: it drew a dark halo around the glass.
        // NOTE: no rotation3DEffect / opacity here. Liquid Glass samples the desktop behind the
        // window, and 3D transforms or a SwiftUI fade force it into an offscreen layer where it
        // can't see the backdrop, so it renders as solid black. Only 2D scale/offset are safe;
        // the fade-in is done on the window itself (see SiriPanelController.show).
        // Pop-in: rises up from below and zooms forward as it settles.
        .scaleEffect(reduceMotion ? 1 : (0.88 + 0.12 * popIn) * hoverLift, anchor: .bottom)
        .offset(y: reduceMotion ? 0 : (1 - popIn) * 18)
        .padding(cardPadding)                       // room for the hover lift
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard !reduceMotion else { return }
            switch phase {
            case .active(let point):
                updateTilt(for: point)
            case .ended:
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { tilt = .zero }
            }
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: PanelSizeKey.self, value: geo.size)
        })
        .onPreferenceChange(PanelSizeKey.self) { panelSize = $0 }
        .onChange(of: model.isPanelVisible) { visible in
            if visible {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { popIn = 1 }
            } else {
                popIn = 0
                tilt = .zero
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: onDismiss)          // Esc
        .onChange(of: model.showCount) { _ in inputFocused = true }
        .onChange(of: model.phase) { _ in inputFocused = true }   // keep typing after each answer
        .onAppear {
            inputFocused = true
            if model.isPanelVisible {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { popIn = 1 }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    @State private var panelSize: CGSize = .zero

    /// visionOS hover: the card lifts slightly toward you while the pointer is over it.
    private var hoverLift: CGFloat { tilt == .zero ? 1 : 1.012 }

    /// The edge under the cursor dips away from you, as if pressing on the glass
    /// (like Apple TV / visionOS parallax).
    private func updateTilt(for point: CGPoint) {
        guard panelSize.width > 0, panelSize.height > 0 else { return }
        let nx = max(-1, min(1, (point.x / panelSize.width) * 2 - 1))
        let ny = max(-1, min(1, (point.y / panelSize.height) * 2 - 1))
        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.8)) {
            tilt = CGSize(width: -ny * maxTilt, height: nx * maxTilt)
        }
    }
}

private struct PanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

extension SiriRootView {

    /// The card background. On macOS 26+ this is the system Liquid Glass material (the same
    /// effect macOS uses for its own search bar), with a smoky dark tint. Older macOS versions
    /// get a frosted-glass fallback.
    @ViewBuilder private var glassCard: some View {
        let shape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(Color.black.opacity(0.22)), in: shape)   // was 0.55: too dark to read as glass
                // Liquid Glass adds its own soft drop shadow outside the shape; clipping to the
                // same shape keeps the glass exactly as is but cuts off that halo.
                .clipShape(shape)
        } else {
            ZStack {
                shape.fill(.thinMaterial)   // thicker frost: blurs away fine detail (e.g. lines of text) behind the panel
                shape.fill(Color.black.opacity(0.10))   // light tint: the desktop behind shows through
            }
        }
    }

    /// A thin glassy rim: light catches the top-left edge, fades along the sides, and picks up
    /// a fainter reflection at the bottom-right, like the bevel of a glass pane.
    private var cardEdge: some View {
        let shape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        return ZStack {
            // Main highlight rim.
            shape.strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.55), location: 0.0),
                        .init(color: .white.opacity(0.12), location: 0.35),
                        .init(color: .white.opacity(0.04), location: 0.6),
                        .init(color: .white.opacity(0.28), location: 1.0),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
            // Faint inner line for a sense of glass thickness.
            shape.inset(by: 0.8).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        }
        .blendMode(.plusLighter)
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            OrbView(active: model.phase == .thinking || model.isListening, paused: !model.isPanelVisible)
                .frame(width: 30, height: 30)

            if model.isListening {
                // Voice mode: no text box, just a waveform that moves with the voice.
                ListeningWave(level: model.audioLevel, paused: !model.isPanelVisible)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Ask Buddy…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .focused($inputFocused)
                    .onSubmit { model.submit() }
            }

            iconButton(
                systemName: "square.and.pencil",
                highlighted: false,
                help: "New chat (⌘N)",
                action: {
                    model.newConversation()
                    inputFocused = true
                }
            )
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.isListening)
            .opacity(model.isListening ? 0.4 : 1)

            iconButton(
                systemName: model.isListening ? "mic.fill" : "mic",
                highlighted: model.isListening,
                help: model.isListening ? "Stop and send" : "Speak your question",
                action: { model.toggleListening() }
            )

        }
    }

    private func iconButton(systemName: String, highlighted: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(highlighted ? Color(red: 1.0, green: 0.31, blue: 0.63) : .white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(highlighted ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Height of the answer area: the answer's real height, up to the cap.
    /// The full height of the answer content, including spacing and the scroll marker.
    private var answerContentHeight: CGFloat {
        let segments = AnswerSegment.parse(model.response)
        let total = segments.reduce(CGFloat(0)) { $0 + AnswerSegment.height($1, width: answerWidth) }
        let spacing = CGFloat(max(segments.count - 1, 0)) * 10
        return total + spacing + 12
    }

    private var answerFrameHeight: CGFloat {
        min(max(answerContentHeight, 20), maxAnswerHeight)
    }

    @ViewBuilder
    private var responseArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.question.isEmpty {
                Text(model.question)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            switch model.phase {
            case .idle:
                EmptyView()

            case .thinking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…")
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .streaming, .done:
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(AnswerSegment.parse(model.response)) { segment in
                                segmentView(segment)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .frame(height: answerFrameHeight)
                    .onChange(of: model.response) { _ in
                        // Only scroll when the answer is longer than the area; otherwise keep the top visible.
                        if answerContentHeight > maxAnswerHeight {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }

            case .failed:
                Text(model.errorMessage)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: AnswerSegment) -> some View {
        switch segment.kind {
        case .text:
            Text(Self.attributed(segment.body))
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.94))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language):
            CodeBlockView(language: language, code: segment.body)
        }
    }

    private static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}

/// One piece of an answer: either prose or a fenced code block.
struct AnswerSegment: Identifiable {
    enum Kind {
        case text
        case code(language: String)
    }

    let id: Int
    let kind: Kind
    let body: String

    /// Splits the answer on ``` fences. An unfinished block (still streaming) counts as code.
    static func parse(_ text: String) -> [AnswerSegment] {
        var segments: [AnswerSegment] = []
        var prose: [String] = []
        var code: [String] = []
        var language = ""
        var inCode = false

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                segments.append(AnswerSegment(id: segments.count, kind: .text, body: joined))
            }
            prose = []
        }

        func flushCode() {
            segments.append(AnswerSegment(id: segments.count, kind: .code(language: language),
                                          body: code.joined(separator: "\n")))
            code = []
            inCode = false
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    flushCode()
                } else {
                    flushProse()
                    language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode { flushCode() }
        flushProse()
        return segments
    }

    /// Rough height of one segment, used to size the answer area.
    static func height(_ segment: AnswerSegment, width: CGFloat) -> CGFloat {
        switch segment.kind {
        case .text:
            return AnswerMeasure.height(for: segment.body, width: width)
        case .code:
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let lines = max(1, segment.body.components(separatedBy: "\n").count)
            return CGFloat(lines) * lineHeight + 36 + 24   // header bar + body padding
        }
    }
}

/// A code block: language label and Copy button in a header bar, code below.
struct CodeBlockView: View {
    let language: String
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button(action: copy) {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color.white.opacity(0.06))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}

/// Animated bars that rise and fall with the microphone level, in the Siri colours.
/// Bars keep a gentle idle motion when the user is quiet, so it always looks alive.
struct ListeningWave: View {
    let level: Float
    /// True while the panel is hidden, so the animation stops redrawing.
    var paused: Bool = false
    private let barCount = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Speech is usually quiet (RMS of roughly 0.02 to 0.2), so scale it up.
            let loudness = CGFloat(min(1, Double(level) * 5))

            HStack(spacing: 4) {
                ForEach(0..<barCount, id: \.self) { i in
                    let wave = (sin(t * 7 + Double(i) * 0.5) + 1) / 2          // 0...1
                    let ripple = (sin(t * 11 + Double(i) * 1.3) + 1) / 2       // 0...1
                    let idle = 0.12 + 0.10 * wave
                    let active = loudness * (0.35 + 0.65 * ripple)
                    let height = 4 + 26 * max(CGFloat(idle), active)

                    Capsule()
                        .fill(LinearGradient(colors: siriColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 30)
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}

/// Small blob in the brand colours. Still while idle; drifts and pulses only while
/// thinking or listening, so an idle open panel causes no redraws at all.
/// Core Animation runs the motion in the system compositor; the app does no per-frame work.
struct OrbView: NSViewRepresentable {
    let active: Bool
    /// Kept for call-site compatibility; hidden windows aren't composited anyway.
    var paused: Bool = false

    func makeNSView(context: Context) -> OrbLayerView { OrbLayerView() }

    func updateNSView(_ view: OrbLayerView, context: Context) {
        view.setActive(active)
    }
}

final class OrbLayerView: NSView {
    private let blob = CALayer()
    private var circles: [CALayer] = []
    private var active = false

    /// Each circle follows the same looping path (x = cos p, y = sin 1.3p), offset in phase.
    private static let loop = 20 * Double.pi          // the path repeats every 20π
    private static func point(_ p: Double) -> NSPoint {
        NSPoint(x: 15 + cos(p) * 6, y: 15 + sin(p * 1.3) * 6)
    }
    private static let phaseOffsets = (0..<4).map { Double($0) * 1.7 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true

        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(4, forKey: kCIInputRadiusKey)
            blob.filters = [blur]
        }
        for i in 0..<4 {
            let circle = CALayer()
            circle.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
            circle.cornerRadius = 9
            circle.backgroundColor = NSColor(siriColors[i]).cgColor
            circle.compositingFilter = "screenBlendMode"
            circle.position = Self.point(Self.phaseOffsets[i])   // resting spot
            circles.append(circle)
            blob.addSublayer(circle)
        }
        layer?.addSublayer(blob)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blob.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
        blob.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func setActive(_ newValue: Bool) {
        guard newValue != active else { return }
        active = newValue
        let frameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)

        guard active else {
            circles.forEach { $0.removeAnimation(forKey: "drift") }
            blob.removeAnimation(forKey: "pulse")
            return
        }

        // Drift: three units of phase per second, starting from each circle's resting spot.
        let steps = 240
        for (i, circle) in circles.enumerated() {
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.values = (0...steps).map { step in
                NSValue(point: Self.point(Self.phaseOffsets[i] + Self.loop * Double(step) / Double(steps)))
            }
            drift.duration = Self.loop / 3
            drift.repeatCount = .infinity
            drift.preferredFrameRateRange = frameRate
            circle.add(drift, forKey: "drift")
        }

        // Pulse between 1.0x and 1.24x, about once a second.
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.24
        pulse.duration = Double.pi / 6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.preferredFrameRateRange = frameRate
        blob.add(pulse, forKey: "pulse")
    }
}
