import AppKit
import ApplicationServices
import CoreGraphics

/// Inserts streamed text at the text cursor of the app being written into, in small chunks,
/// so the answer appears live.
///
/// Two ways to insert, picked per app:
///
/// 1. Accessibility (native apps: Mail, Notes, TextEdit, Pages…). Each chunk is set as the
///    focused element's selected text, which inserts it at the cursor. No clipboard, no
///    keystrokes, exact. After the first chunk it checks the cursor really moved; if the app
///    ignored it, it switches to pasting.
/// 2. Paste (web content: browsers such as Chrome/Gmail and Electron apps, whose Accessibility
///    inserts apply asynchronously and overlap).
///    Each chunk goes on the clipboard as a promise and is pasted with ⌘V. The next chunk
///    waits until the app has read the previous one, plus a safety gap.
///
/// Simulated per-character keystrokes are not used: Gmail's compose box dropped and reordered
/// them (lost letters and spaces), and macOS "Add period with double-space" turned the garbled
/// spaces into stray ". ".
///
/// The user's clipboard is saved before the first paste and restored afterwards (unless they
/// copied something new meanwhile), and chunks are marked transient so clipboard managers skip them.
final class CaretTyper: NSObject, NSPasteboardItemDataProvider {
    /// Called when everything queued has been inserted.
    var onDrained: (() -> Void)?
    /// Asked right before every insert. Returning false stops writing (`onTargetLost` is called),
    /// so nothing lands anywhere but the field the user started in.
    var isTargetStillValid: (() -> Bool)?
    var onTargetLost: (() -> Void)?

    /// Tags SiriAsk's own ⌘V events so the "user pressed a key, stop" monitor can ignore them.
    static let syntheticEventTag: Int64 = 0x5349_5249   // 'SIRI'

    /// While true, text is queued but not inserted (used while focus returns to the target app).
    var isHeld = false {
        didSet { if !isHeld { startTimerIfNeeded() } }
    }

    var isIdle: Bool { buffer.isEmpty && unreadChunk == nil }

    private enum Method { case accessibility(AXUIElement), paste }
    private var method: Method = .paste
    /// True until the first Accessibility insert has been checked.
    private var verifyNextAXInsert = false

    private var buffer = ""
    private var timer: Timer?
    private let source = CGEventSource(stateID: .privateState)

    private let tickInterval: TimeInterval = 0.05
    /// Minimum time between Accessibility inserts (keeps the live-typing look).
    private let axGap: TimeInterval = 0.06
    /// Minimum time between pastes, and a longer one after the first: a just-focused browser
    /// can take a while to handle its first ⌘V.
    private let pasteGap: TimeInterval = 0.25
    private let firstPasteGap: TimeInterval = 0.6
    /// If the app never reads a pasted chunk (it ignored ⌘V), stop waiting after this long.
    private let readTimeout: TimeInterval = 2.0
    /// How long after the last paste the user's clipboard is put back.
    private let restoreDelay: TimeInterval = 1.0

    private var lastInsertAt = Date.distantPast
    private var pasteCount = 0

    private var unreadChunk: String?
    /// Kept so a second read of the same clipboard item (some apps read twice) gets the same text.
    private var lastChunk: String?
    private var savedClipboard: [NSPasteboardItem]?
    private var lastWriteChangeCount: Int?
    private var restoreWork: DispatchWorkItem?

    /// Call before each write. Uses Accessibility when the element accepts it, otherwise paste.
    func begin(target element: AXUIElement?) {
        cancel()
        pasteCount = 0
        lastInsertAt = .distantPast
        if let element, !Self.isInWebContent(element), Self.canSetSelectedText(element) {
            method = .accessibility(element)
            verifyNextAXInsert = true
        } else {
            method = .paste
        }
    }

    func enqueue(_ text: String) {
        guard !text.isEmpty else { return }
        buffer += text
        startTimerIfNeeded()
    }

    /// Stops inserting and drops anything not yet inserted.
    func cancel() {
        stopTimer()
        buffer = ""
        unreadChunk = nil
        scheduleRestore()
    }

    private func startTimerIfNeeded() {
        guard timer == nil, !isHeld, !buffer.isEmpty else { return }
        tick()   // first chunk right away; the rest on the timer
        guard timer == nil else { return }
        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !isHeld else { stopTimer(); return }
        let since = Date().timeIntervalSince(lastInsertAt)

        switch method {
        case .accessibility(let element):
            guard !buffer.isEmpty else { return drained() }
            guard since >= axGap else { return }
            guard isTargetStillValid?() ?? true else { return targetLost() }
            let chunk = buffer
            buffer = ""
            lastInsertAt = Date()
            if !insertWithAccessibility(chunk, into: element) {
                // The app refused or ignored it: paste this chunk and everything after it.
                method = .paste
                buffer = chunk + buffer
                lastInsertAt = .distantPast
            }

        case .paste:
            if unreadChunk != nil && since < readTimeout { return }   // wait for the app to read it
            unreadChunk = nil
            guard !buffer.isEmpty else {
                // Let the last paste land before reporting done (and before the clipboard is restored).
                guard since >= pasteGap else { return }
                return drained()
            }
            guard since >= (pasteCount == 1 ? firstPasteGap : pasteGap) else { return }
            guard isTargetStillValid?() ?? true else { return targetLost() }
            let chunk = buffer
            buffer = ""
            paste(chunk)
        }
    }

    private func targetLost() {
        cancel()
        onTargetLost?()
    }

    private func drained() {
        stopTimer()
        scheduleRestore()
        onDrained?()
    }

    // MARK: - Accessibility

    /// True for text inside a web page (browsers, Electron apps). Their Accessibility setters
    /// apply asynchronously, so quick successive inserts overlap and duplicate text: paste there.
    private static func isInWebContent(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let el = current else { return false }
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success,
               role as? String == "AXWebArea" { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    private static func canSetSelectedText(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    /// Inserts at the cursor (replacing any selection). The first insert is checked: the
    /// cursor must end up right after the inserted text, or the app silently ignored it.
    private func insertWithAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        let before = Self.selectedRange(element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        guard verifyNextAXInsert else { return true }
        verifyNextAXInsert = false
        guard let before, let after = Self.selectedRange(element) else { return false }
        return after.location == before.location + (text as NSString).length
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    // MARK: - Paste

    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        restoreWork?.cancel()
        if savedClipboard == nil {
            savedClipboard = Self.snapshot(pb)
        }
        lastChunk = nil
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])   // text is supplied when the app reads it
        // nspasteboard.org markers: clipboard managers skip transient/concealed items.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])
        lastWriteChangeCount = pb.changeCount
        unreadChunk = text
        lastInsertAt = Date()
        pasteCount += 1
        pressCommandV()
    }

    /// The clipboard is being read (normally the paste): hand over the chunk.
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .string, let chunk = unreadChunk ?? lastChunk else { return }
        item.setString(chunk, forType: .string)
        lastChunk = chunk
        unreadChunk = nil
    }

    private func pressCommandV() {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: keyDown) else { continue }   // V
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Puts the user's clipboard back once the target app has had time to read the last chunk.
    private func scheduleRestore() {
        guard savedClipboard != nil else { return }
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restoreClipboard() }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
    }

    private func restoreClipboard() {
        guard let saved = savedClipboard else { return }
        let pb = NSPasteboard.general
        // If the user copied something since our last chunk, keep theirs.
        if pb.changeCount == lastWriteChangeCount {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        savedClipboard = nil
        lastWriteChangeCount = nil
    }

    /// A deep copy of every item and type on the pasteboard.
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}
