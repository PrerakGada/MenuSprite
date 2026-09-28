import AppKit
import ApplicationServices
import IslandKit

/// The Notifications section's state on the main actor: whether the reader can run, the inbox,
/// which message is being opened and which could not be. Messages live only here, in memory, and
/// are dropped on `stop()` (lock, sleep, the section or the island switched off, Accessibility
/// withdrawn).
@MainActor
final class NotificationMirrorStore: ObservableObject {
    enum Status: Equatable {
        /// Not running: the island is off or the section hidden.
        case off
        /// Running, but Notification Center's process is not (yet) attached.
        case waiting
        case attached
    }

    @Published private(set) var status: Status = .off
    /// Accessibility trust as last checked (never prompted for here).
    @Published private(set) var trusted = false
    @Published private(set) var inbox = NotificationInbox()
    /// The message whose Open is in flight; only one at a time.
    @Published private(set) var opening: Int?
    /// Messages whose Open failed: their cards say so.
    @Published private(set) var failed: Set<Int> = []

    /// A new message arrived (never for the baseline read; only the newest of a burst).
    var onArrival: (NotificationMirror) -> Void = { _ in }
    /// A read failed and Accessibility turned out to be withdrawn.
    var onTrustLost: () -> Void = {}

    private var reader: NotificationAXReader?
    private var generation = 0
    private var attachedPID: pid_t?
    /// Set only by the render samples: the trust state they show.
    private var sampleTrust: Bool?
    private var closeAllowed = false
    private var icons: [String: NSImage] = [:]
    private var closeTasks: [Int: Task<Void, Never>] = [:]

    var mirrors: [NotificationMirror] { inbox.mirrors }

    /// Re-reads Accessibility trust (a cheap check, no prompt). Returns the new value.
    @discardableResult
    func refreshTrust() -> Bool {
        let now = sampleTrust ?? AXIsProcessTrusted()
        if trusted != now { trusted = now }
        return now
    }

    // MARK: Running

    func start() {
        guard status == .off else { return }
        let reader = NotificationAXReader { [weak self] generation, event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, generation: generation) } }
        }
        reader.gate.setCloseAllowed(closeAllowed)
        self.reader = reader
        status = .waiting
        generation = reader.gate.begin()
        reader.attach(generation: generation)
    }

    /// Some app launched or quit: re-attach if Notification Center's process appeared, restarted or
    /// went away.
    func checkNotificationCenter() {
        guard status != .off else { return }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: NotificationAX.bundleID)
            .first(where: { !$0.isTerminated })?.processIdentifier
        if pid != attachedPID { reattach() }
    }

    /// Attach afresh: a new baseline, messages kept.
    func reattach() {
        guard status != .off, let reader else { return }
        generation = reader.gate.begin()
        reader.attach(generation: generation)
    }

    func stop() {
        closeTasks.values.forEach { $0.cancel() }
        closeTasks.removeAll()
        if let reader {
            reader.gate.end()
            reader.detach()
        }
        reader = nil
        attachedPID = nil
        inbox.reset()
        opening = nil
        failed = []
        icons = [:]
        if status != .off { status = .off }
    }

    /// The "Close the macOS banner" option and the island being closed, as one switch the reader
    /// checks right before it acts.
    func setCloseAllowed(_ allowed: Bool) {
        closeAllowed = allowed
        reader?.gate.setCloseAllowed(allowed)
    }

    private func handle(_ event: NotificationReaderEvent, generation: Int) {
        guard generation == self.generation, status != .off else { return }
        switch event {
        case .waiting:
            status = .waiting
            attachedPID = nil
            inbox.rebaseline()
        case .attached(let pid):
            status = .attached
            attachedPID = pid
            inbox.rebaseline()
        case .snapshot(.complete(let items)):
            let arrivals = inbox.apply(items, at: Date())
            let ids = Set(inbox.mirrors.map(\.id))
            failed.formIntersection(ids)
            pruneIcons()
            // A burst read at once shows only its newest message; the rest wait in the inbox, and
            // their native banners are never closed unseen.
            if let newest = arrivals.last { onArrival(newest) }
        case .snapshot(.skipped):
            break
        case .snapshot(.failed):
            if !refreshTrust() { onTrustLost() }
        }
    }

    // MARK: Actions

    func dismiss(_ id: Int) {
        inbox.dismiss(id)
        failed.remove(id)
        pruneIcons()
    }

    func removeAll() {
        inbox.removeAll()
        failed = []
        icons = [:]
    }

    /// Opens the message the way a click on the native banner would; if that banner is gone or
    /// cannot be pressed, opens its app instead. `completion` gets false when neither worked.
    func open(_ id: Int, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard opening == nil, let mirror = inbox.mirror(id) else { return }
        opening = id
        failed.remove(id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let opened = await self.performOpen(mirror)
            self.opening = nil
            if !opened, self.inbox.mirror(id) != nil { self.failed.insert(id) }
            completion(opened)
        }
    }

    private func performOpen(_ mirror: NotificationMirror) async -> Bool {
        if mirror.canOpenNatively, let reader {
            switch await reader.perform(.press, on: mirror.key, generation: generation) {
            case .done: return true
            case .uncertain, .cancelled: return false
            case .unavailable: break
            }
        }
        return await Self.launch(mirror.source)
    }

    /// Launches the source app, only when the app found for its bundle identifier really is that app.
    private static func launch(_ source: NotificationSource?) async -> Bool {
        guard let bundleID = source?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              Bundle(url: url)?.bundleIdentifier == bundleID else { return false }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            return false
        }
    }

    /// Closes the native banner after a short grace, if `stillWanted` still says so then. The
    /// reader validates the banner again and re-checks the option right before acting.
    func scheduleClose(_ mirror: NotificationMirror, stillWanted: @escaping @MainActor () -> Bool) {
        guard let live = mirror.live, !live.isPersistent, live.closeAction != nil else { return }
        closeTasks[mirror.id]?.cancel()
        closeTasks[mirror.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NotificationTiming.closeGrace))
            guard !Task.isCancelled, let self, stillWanted(), let reader = self.reader else { return }
            let key = self.inbox.mirror(mirror.id)?.key ?? mirror.key
            _ = await reader.perform(.close, on: key, generation: self.generation)
            self.closeTasks[mirror.id] = nil
        }
    }

    // MARK: Icons

    /// The source app's icon, cached per app while one of its messages is in the inbox.
    func icon(for mirror: NotificationMirror) -> NSImage? {
        guard let source = mirror.source, let key = source.bundleID ?? source.name else { return nil }
        if let cached = icons[key] { return cached }
        let path = source.path ?? source.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
        guard let path else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[key] = image
        return image
    }

    private func pruneIcons() {
        let keep = Set(inbox.mirrors.compactMap { $0.source?.bundleID ?? $0.source?.name })
        icons = icons.filter { keep.contains($0.key) }
    }

    // MARK: Render samples

    /// Fills the inbox with sample messages for the off-screen render harness. Never used live.
    func loadSamples(_ items: [NotificationSnapshotItem], trusted: Bool) {
        sampleTrust = trusted
        self.trusted = trusted
        status = .attached
        inbox.reset()
        inbox.apply([], at: Date())
        let start = Date().addingTimeInterval(-Double(items.count) * 240)
        for index in items.indices {
            inbox.apply(Array(items[...index]), at: start.addingTimeInterval(Double(index) * 240))
        }
    }
}
