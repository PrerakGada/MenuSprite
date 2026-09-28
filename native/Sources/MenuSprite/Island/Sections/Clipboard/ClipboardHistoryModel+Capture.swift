import AppKit
import IslandKit

/// Watching the pasteboard. The change count is polled every 0.8 s (0.25 s tolerance) only while the
/// island runs, "Keep clipboard history" is on, the history loaded and macOS lets MenuSprite read
/// other apps' copies without asking. While macOS would ask, nothing is read: an app-activation
/// observer re-checks the answer (the person may be changing it in System Settings) instead.
extension ClipboardHistoryModel {
    var wantsCapture: Bool { islandRunning && preferences.keepHistory && !isPreview }
    var isCapturing: Bool { timer != nil }

    func syncCapture() {
        guard wantsCapture else {
            stopCapture()
            stopAccessWatch()
            releaseIfIdle()
            return
        }
        ensureLoaded()
        refreshAccess()
    }

    /// Asks macOS for its current answer (no content is read) and starts or stops capture to match.
    func refreshAccess() {
        guard !isPreview else { return }
        ClipboardPasteboard.access(pasteboardName) { [weak self] access in self?.accessUpdated(access) }
    }

    /// Only after the person pressed "Ask macOS": one real read, so macOS shows its alert.
    func askSystem() {
        guard !isPreview else { return }
        ClipboardPasteboard.askSystem(pasteboardName) { [weak self] access in self?.accessUpdated(access) }
    }

    func accessUpdated(_ value: ClipboardReadAccess) {
        let changed = access != value
        access = value
        applyCapture()
        if changed { dependenciesChanged() }
    }

    private func applyCapture() {
        if wantsCapture, load == .ready, access?.allowsAutomaticReads == true {
            startCapture()
            stopAccessWatch()
        } else {
            stopCapture()
            if wantsCapture, let access, !access.allowsAutomaticReads { startAccessWatch() } else { stopAccessWatch() }
            releaseIfIdle()
        }
    }

    private func startCapture() {
        guard timer == nil else { return }
        gate.start()
        let timer = Timer(timeInterval: ClipboardCaptureGate.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = ClipboardCaptureGate.tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        frontmostSincePoll = currentFrontmost()
        syncIgnoreObserver()
    }

    func stopCapture() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        gate.stop()
        syncIgnoreObserver()
    }

    private func tick() {
        guard let ticket = gate.admit(now: Date()) else { return }
        let frontmost = frontmostSincePoll
        frontmostSincePoll = currentFrontmost()
        let options = ClipboardReadOptions(includeMedia: preferences.includeMedia, skipSensitive: preferences.skipSensitive)
        ClipboardPasteboard.poll(pasteboardName, ticket: ticket, options: options) { [weak self] count, result in
            self?.pollFinished(ticket, count: count, result: result, frontmost: frontmost)
        }
    }

    private func pollFinished(_ ticket: ClipboardCaptureGate.Ticket, count: Int, result: ClipboardReadResult, frontmost: Set<String>) {
        let outcome = gate.complete(ticket, count: count, now: Date())
        if case .blocked(let value) = result {
            accessUpdated(value)
            return
        }
        guard outcome == .new, !ClipboardPrivacy.skips(frontmost: frontmost, ignored: Set(preferences.ignoredApps)) else { return }
        record(result)
    }

    /// Keeps a new copy: its image or rich text goes to disk first, then the entry.
    private func record(_ result: ClipboardReadResult) {
        let now = Date()
        let entry: ClipboardEntry
        switch result {
        case .text(let text, let rtf):
            var rich: ClipboardRichText?
            if let rtf, let store {
                let file = UUID().uuidString + ".rtf"
                store.writeAsset(rtf, to: store.richFolder.appendingPathComponent(file))
                rich = ClipboardRichText(file: file, bytes: rtf.count)
            }
            entry = .text(text, rich: rich, at: now)
        case .image(let image):
            let existing = history.entries.first { $0.kind == .image && $0.image?.sha256 == image.sha256 }?.image?.file
            let file = existing ?? UUID().uuidString + ".png"
            if existing == nil, let store { store.writeAsset(image.png, to: store.imagesFolder.appendingPathComponent(file)) }
            if let thumbnail = image.thumbnail { thumbnails.seed(file, thumbnail) }
            entry = .image(ClipboardImage(file: file, sha256: image.sha256, width: image.width, height: image.height,
                                          bytes: image.png.count), at: now)
        case .files(let paths):
            entry = .files(paths, at: now)
        case .unchanged, .blocked, .skipped:
            return
        }
        guard history.record(entry, limit: preferences.limit) != .dropped else { return }
        changed()
        onCaptured()
    }

    // MARK: Apps to skip

    /// The frontmost app's bundle id, when an ignore list exists (otherwise nothing is tracked).
    private func currentFrontmost() -> Set<String> {
        guard !preferences.ignoredApps.isEmpty, let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return [] }
        return [bundle]
    }

    /// Watches app activations only while capturing with a non-empty ignore list, so a copy made in
    /// a listed app is dropped even if another app is in front by the time it is read.
    func syncIgnoreObserver() {
        let wanted = timer != nil && !preferences.ignoredApps.isEmpty
        if wanted, activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    if let bundle { self?.frontmostSincePoll.insert(bundle) }
                }
            }
        } else if !wanted, let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
    }

    // MARK: Waiting for macOS

    /// While macOS would ask, re-check its answer whenever an app comes to the front (for example on
    /// leaving System Settings). No timer.
    private func startAccessWatch() {
        guard accessObserver == nil else { return }
        accessObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        }
    }

    func stopAccessWatch() {
        guard let observer = accessObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        accessObserver = nil
    }
}
