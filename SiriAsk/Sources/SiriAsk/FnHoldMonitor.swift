import AppKit
import CoreGraphics

/// Runs `onHold` when the fn (Globe) key is held down on its own for a moment.
///
/// - A quick tap of fn does nothing, so normal fn use is unaffected.
/// - Pressing fn together with another key or modifier (fn+arrow, fn+F1, fn+Shift…) cancels the hold.
/// - Needs Input Monitoring permission to see fn while other apps are in front.
final class FnHoldMonitor {
    private let holdDuration: TimeInterval
    private let onHold: () -> Void
    private var pending: DispatchWorkItem?
    private var monitors: [Any] = []

    init(holdDuration: TimeInterval = 0.4, onHold: @escaping () -> Void) {
        self.holdDuration = holdDuration
        self.onHold = onHold

        // Ask once for Input Monitoring so the global fn monitor can work.
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }

        // Other apps: global monitors (they never see events sent to SiriAsk itself).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlags(event)
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            self?.cancelPending()
        }) { monitors.append(m) }

        // SiriAsk's own windows: local monitors.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlags(event)
            return event
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.cancelPending()
            return event
        }) { monitors.append(m) }
    }

    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
        cancelPending()
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags
        let otherModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

        guard flags.contains(.function), flags.intersection(otherModifiers).isEmpty else {
            // fn was released, or another modifier joined it.
            cancelPending()
            return
        }

        // fn just went down: fire only if it is still down after the hold duration.
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.onHold()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: work)
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}
