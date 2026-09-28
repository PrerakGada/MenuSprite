import AppKit
import Carbon.HIToolbox
import IslandKit

/// Putting an entry back: copy it, or paste it into the app that was in front. Pasting sends ⌘V,
/// which needs Accessibility; MenuSprite only checks that here and never asks, so without it the
/// entry is copied and the page says so.
extension ClipboardHistoryModel {
    /// Click, Return or ⌘1–⌘9. `collapse` hides the surface before a paste, so ⌘V lands in the app.
    func activate(_ entry: ClipboardEntry, collapse: @escaping () -> Void) {
        let trusted = AXIsProcessTrusted()
        accessibilityTrusted = trusted
        let decision = ClipboardActivation.decide(trusted: trusted, target: targetState)
        if decision == .paste { collapse() }
        let target = pasteTarget
        writeBack(entry) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.writeFailed(); return }
            switch decision {
            case .paste: self.paste(into: target, entry: entry.id)
            case .copy: self.markCopied(entry.id)
            case .copyNeedsAccessibility:
                self.markCopied(entry.id)
                self.show("Copied. To paste straight into apps, allow MenuSprite in Accessibility.")
            case .copyTargetGone:
                self.markCopied(entry.id)
                NSSound.beep()
            }
        }
    }

    /// The Copy button: always a copy, never a paste.
    func copy(_ entry: ClipboardEntry) {
        writeBack(entry) { [weak self] ok in
            if ok { self?.markCopied(entry.id) } else { self?.writeFailed() }
        }
    }

    var targetState: ClipboardActivation.Target {
        guard let pasteTarget else { return .none }
        return pasteTarget.isTerminated ? .terminated : .running
    }

    var pasteTargetName: String? { pasteTarget.flatMap { $0.isTerminated ? nil : $0.localizedName } }

    /// One write at a time; a second one fails at once. The app's own write never becomes an entry.
    private func writeBack(_ entry: ClipboardEntry, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard !writing else { completion(false); return }
        writing = true
        ClipboardPasteboard.write(entry, image: store?.imageURL(entry.image), rich: store?.richURL(entry.rich),
                                  to: pasteboardName) { [weak self] outcome in
            guard let self else { return }
            self.writing = false
            guard case .written(let count) = outcome else { completion(false); return }
            self.gate.noteOwnWrite(count: count)
            self.history.touch(entry.id, at: Date())
            self.changed()
            completion(true)
        }
    }

    private func writeFailed() {
        NSSound.beep()
        show("That item could not be copied. Its image or files may be gone.")
    }

    private func markCopied(_ id: UUID) {
        copiedID = id
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.copiedID = nil
        }
    }

    /// Brings the remembered app forward and sends ⌘V only once it is really in front
    /// (`ClipboardPasteHandoff`); otherwise the entry stays copied and the island says to press ⌘V.
    /// The previous clipboard is not restored.
    private func paste(into target: NSRunningApplication?, entry: UUID) {
        cancelHandoff()
        guard let target, !target.isTerminated else { pasteFellBack(.targetGone, entry: entry); return }
        target.activate()
        handoff = ClipboardPasteHandoff(target: target.processIdentifier, own: ProcessInfo.processInfo.processIdentifier,
                                        started: Date())
        let timer = Timer(timeInterval: ClipboardPasteHandoff.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHandoff(target, entry: entry) }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        handoffTimer = timer
        checkHandoff(target, entry: entry)
    }

    private func checkHandoff(_ target: NSRunningApplication, entry: UUID) {
        guard var handoff else { cancelHandoff(); return }
        let observation = ClipboardPasteHandoff.Observation(
            frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownWindowHasKeyboard: NSApp.keyWindow != nil,
            targetTerminated: target.isTerminated,
            trusted: AXIsProcessTrusted())
        let step = handoff.check(observation, now: Date())
        self.handoff = handoff
        switch step {
        case .wait: return
        case .post:
            cancelHandoff()
            Self.postCommandV()
        case .giveUp(let reason):
            cancelHandoff()
            pasteFellBack(reason, entry: entry)
        case .done:
            cancelHandoff()
        }
    }

    private func cancelHandoff() {
        handoffTimer?.invalidate()
        handoffTimer = nil
        handoff = nil
    }

    /// The entry is on the pasteboard but was not pasted.
    private func pasteFellBack(_ reason: ClipboardPasteHandoff.GiveUp, entry: UUID) {
        markCopied(entry)
        switch reason {
        case .targetNotFront: show("Copied. Paste it with ⌘V.")
        case .targetGone:
            NSSound.beep()
            show("Copied. The app you were using has quit.")
        case .notTrusted: show("Copied. To paste straight into apps, allow MenuSprite in Accessibility.")
        }
        onPasteFallback()
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: The app to paste into

    /// Remembered when a surface opens and whenever another app becomes active while it is open:
    /// a regular app that is still running and is not MenuSprite.
    func rememberFrontmost(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular, !app.isTerminated else { return }
        pasteTarget = app
    }

    func startTargetWatch() {
        guard targetObserver == nil else { return }
        targetObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.rememberFrontmost(app) }
        }
    }

    func stopTargetWatch() {
        guard let observer = targetObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        targetObserver = nil
    }

    // MARK: System Settings

    static func openPasteSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(url) }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
