import AppKit
import ApplicationServices

/// A snapshot of where the user's text cursor is, taken through the Accessibility API
/// just before the write-at-cursor prompt opens.
///
/// Needs Accessibility permission (System Settings › Privacy & Security › Accessibility).
struct CaretContext {
    let app: NSRunningApplication
    /// The focused text element, used to insert text through Accessibility when the app allows it.
    let element: AXUIElement?
    /// Text cursor in Cocoa screen coordinates (bottom-left origin), if the app reports it.
    let caretRect: NSRect?
    let windowTitle: String?
    /// Text the user had selected. The written output replaces it.
    let selectedText: String
    /// Text already in the field around the cursor, sent to Claude as context.
    let textBefore: String
    let textAfter: String
    /// True for password fields: nothing is read from them and nothing is typed into them.
    let isSecure: Bool
    /// True when the app exposed a focused text element (false = typing blind, e.g. a terminal).
    let hasTextElement: Bool
    /// What the focused element is: a text input, something else (a file list, a button…),
    /// or unknown (the app didn't answer, e.g. Chrome before its accessibility tree is built).
    let focusKind: FocusKind
    /// The target app's focused window when the prompt opened (to notice if it changes).
    let window: AXUIElement?

    enum FocusKind { case text, notText, unknown }

    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField",
    ]

    var appName: String { app.localizedName ?? "the app" }

    /// How much surrounding text is sent as context (UTF-16 units).
    private static let maxBefore = 4000
    private static let maxAfter = 1500

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt (only the first time).
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Reads the frontmost app's focused text field. Returns nil if there is no frontmost app.
    static func capture() -> CaretContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Chrome and Electron apps only build their accessibility tree when asked to.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let window = focusedWindow(in: app)
        let windowTitle = window.flatMap { string($0, kAXTitleAttribute) }

        guard let focused = element(appElement, kAXFocusedUIElementAttribute)
                ?? element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else {
            // Only browser engines (Chrome, Electron…) are allowed to be "unknown": their
            // accessibility tree is often not ready. Any other app that can't name a focused
            // text field has no text cursor (e.g. the desktop), so nothing is written.
            return CaretContext(app: app, element: nil, caretRect: nil, windowTitle: windowTitle, selectedText: "",
                                textBefore: "", textAfter: "", isSecure: false, hasTextElement: false,
                                focusKind: isWebEngineApp(app) ? .unknown : .notText, window: window)
        }

        let subrole = string(focused, kAXSubroleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) {
            return CaretContext(app: app, element: focused, caretRect: frameCaret(focused), windowTitle: windowTitle, selectedText: "",
                                textBefore: "", textAfter: "", isSecure: true, hasTextElement: true,
                                focusKind: .text, window: window)
        }

        let range = selectedRange(focused)
        let selected = string(focused, kAXSelectedTextAttribute) ?? ""
        var before = ""
        var after = ""
        if let value = string(focused, kAXValueAttribute), let range {
            let ns = value as NSString
            let start = min(max(range.location, 0), ns.length)
            let end = min(start + max(range.length, 0), ns.length)
            let from = max(0, start - maxBefore)
            before = ns.substring(with: NSRange(location: from, length: start - from))
            after = ns.substring(with: NSRange(location: end, length: min(maxAfter, ns.length - end)))
        }

        let caret = range.flatMap { caretRect(focused, range: $0) } ?? frameCaret(focused)
        let isText = isTextInput(focused)
        return CaretContext(app: app, element: focused, caretRect: caret, windowTitle: windowTitle, selectedText: selected,
                            textBefore: before, textAfter: after, isSecure: false,
                            hasTextElement: range != nil, focusKind: isText ? .text : .notText,
                            window: window)
    }

    // MARK: - Is the cursor still where it was?

    /// The element that has keyboard focus in `app` right now (nil if the app doesn't say).
    static func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
    }

    /// The app's focused window (its document/main window, not transient helper windows).
    static func focusedWindow(in app: NSRunningApplication) -> AXUIElement? {
        element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
    }

    /// A real text input: a text role, or an element whose text can be edited. A selection
    /// range alone is not enough: Finder's desktop (AXGroup/AXDesktop) reports one too.
    static func isTextInput(_ el: AXUIElement) -> Bool {
        let role = string(el, kAXRoleAttribute) ?? ""
        let subrole = string(el, kAXSubroleAttribute) ?? ""
        if subrole == "AXDesktop" { return false }
        return textRoles.contains(role) || isEditable(el)
    }

    /// Chromium-based browsers and Electron apps ship a "<Name> Framework.framework"
    /// (e.g. "Google Chrome Framework", "Electron Framework").
    static func isWebEngineApp(_ app: NSRunningApplication) -> Bool {
        guard let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else { return false }
        return names.contains { $0.hasSuffix(" Framework.framework") }
    }

    private static func isEditable(_ el: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        for attr in [kAXSelectedTextAttribute, kAXValueAttribute] {
            if AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success, settable.boolValue,
               string(el, kAXValueAttribute) != nil { return true }
        }
        return false
    }

    // MARK: - Caret position

    /// Bounds of the insertion point. Apps differ: some answer for an empty range, some only
    /// for the character after (or before) the cursor.
    private static func caretRect(_ el: AXUIElement, range: CFRange) -> NSRect? {
        if let r = bounds(el, CFRange(location: range.location, length: range.length)), r.height > 0 {
            return toCocoa(CGRect(x: r.minX, y: r.minY, width: 1, height: r.height))
        }
        if let r = bounds(el, CFRange(location: range.location, length: 1)), r.height > 0 {
            return toCocoa(CGRect(x: r.minX, y: r.minY, width: 1, height: r.height))
        }
        if range.location > 0, let r = bounds(el, CFRange(location: range.location - 1, length: 1)), r.height > 0 {
            return toCocoa(CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height))
        }
        return nil
    }

    /// Fallback: the top-left corner of the focused element.
    private static func frameCaret(_ el: AXUIElement) -> NSRect? {
        guard let posValue = axValue(el, kAXPositionAttribute),
              let sizeValue = axValue(el, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &pos), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        let lineHeight = min(max(size.height, 1), 20)
        return toCocoa(CGRect(x: pos.x + 6, y: pos.y + 4, width: 1, height: lineHeight))
    }

    private static func bounds(_ el: AXUIElement, _ range: CFRange) -> CGRect? {
        var r = range
        guard let rangeValue = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                el, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
        // Some apps answer (0,0,0,0) instead of failing.
        if rect.origin == .zero && rect.size == .zero { return nil }
        return rect
    }

    /// Accessibility uses top-left-origin global coordinates; AppKit uses bottom-left.
    /// Returns nil if the point is not on any screen (a bogus answer from the app).
    private static func toCocoa(_ r: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let rect = NSRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
        let onScreen = NSScreen.screens.contains { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
        return onScreen ? rect : nil
    }

    // MARK: - AX helpers

    private static func raw(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = raw(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func axValue(_ el: AXUIElement, _ name: String) -> AXValue? {
        guard let v = raw(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        raw(el, name) as? String
    }

    private static func selectedRange(_ el: AXUIElement) -> CFRange? {
        guard let v = axValue(el, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        return AXValueGetValue(v, .cfRange, &range) ? range : nil
    }
}
