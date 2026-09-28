import AppKit
import Combine
import IslandKit

/// The island's view of Now Playing: which player it follows, what that player is playing, and the
/// command in flight. The page, the Controls card, the compact strip and the notice all read this
/// one object; the reader behind it runs only while `setRunning(true)` is in effect.
@MainActor
final class MusicModel: ObservableObject {
    enum Phase: Equatable {
        /// The reader is not running.
        case off
        /// Started, restarted or switching source, with no answer yet: blank space, never a flash of
        /// "Nothing playing".
        case waiting
        /// Nothing to show; the chooser may still list players.
        case idle
        /// A recording, playing or paused.
        case ready
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var playback: MusicPlayback?
    /// Monotonic time the playback was read at, so the position can move between readings.
    @Published private(set) var readAt: Double = 0
    @Published private(set) var cover: MusicCover?
    @Published private(set) var sources: [MusicSource] = []
    @Published private(set) var chosenPID: Int32?
    @Published private(set) var isPending = false
    @Published private(set) var commandFailed = false
    @Published private(set) var scrub: MusicScrub?

    /// Every accepted reading, or nil when playback went away.
    var onPlayback: (MusicPlayback?) -> Void = { _ in }
    /// The reader started afresh or the person picked another source: track memory starts over.
    var onRestart: () -> Void = {}

    private let reader = NowPlayingReader()
    private let options: MusicOptions
    private var selection = MusicSelection()
    private var discovery: MusicDiscovery?
    private var follow: MusicSourceKey?
    private var extras: [MusicSourceKey] = []
    private var sequence = 0
    private var tracker = MusicArtworkTracker<MusicCover>()
    private var nextID = 1
    private var pendingID: Int?
    private var pendingTimeout: Task<Void, Never>?
    private var bridgeCheck: Task<Void, Never>?
    private var coverCheck: Task<Void, Never>?
    private var scrubCheck: Task<Void, Never>?
    private var optionsObservation: AnyCancellable?

    init(options: MusicOptions) {
        self.options = options
        reader.onEvent = { [weak self] event in self?.handle(event) }
        optionsObservation = options.$includeOtherPlayers.dropFirst().removeDuplicates().sink { [weak self] _ in
            // The publisher fires before the value is stored.
            Task { @MainActor in self?.reselect() }
        }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: Running

    var isRunning: Bool { reader.isWanted }

    func setRunning(_ running: Bool) {
        guard running != reader.isWanted else { return }
        if running {
            phase = .waiting
            reader.start()
        } else {
            reader.stop()
            reset(to: .off)
        }
    }

    /// Forgets playback state and cancels what is in flight; the manual choice survives for the next
    /// adapter.
    private func reset(to phase: Phase) {
        self.phase = phase
        playback = nil
        cover = nil
        sources = []
        chosenPID = selection.chosen?.pid
        discovery = nil
        follow = nil
        extras = []
        tracker.reset()
        selection.forgetFollowed()
        releasePending(failed: false)
        scrub = nil
        bridgeCheck?.cancel()
        coverCheck?.cancel()
        onPlayback(nil)
    }

    private func handle(_ event: NowPlayingReader.Event) {
        switch event {
        case .launched:
            if phase != .waiting { reset(to: .waiting) }
            onRestart()
            sendTarget()
        case .interrupted:
            reset(to: .waiting)
        case .gaveUp:
            reset(to: .idle)
        case .writeFailed(let id):
            if id == pendingID { releasePending(failed: true) }
        case .reply(let reply, let cover):
            receive(reply, cover: cover)
        }
    }

    private func receive(_ reply: MusicReply, cover decoded: MusicCover?) {
        switch reply {
        case .sources(let found):
            discovery = found
            reselect()
        case .playback(var value):
            guard value.sequence == sequence, value.key == follow else { return }
            let input: MusicArtworkTracker<MusicCover>.Input
            switch value.artwork {
            case .bytes: input = decoded.map { .cover($0) } ?? .missing
            case .unchanged: input = .unchanged
            case .missing: input = .missing
            }
            value.artwork = .missing
            tracker.receive(input, player: value.key, recording: value.revision, now: now)
            scheduleCoverCheck()
            cover = tracker.shown
            if let scrub, scrub.revision != value.revision { self.scrub = nil }
            if playback?.revision != value.revision { commandFailed = false }
            playback = value
            readAt = now
            phase = .ready
            onPlayback(value)
        case .empty(let replySequence):
            guard replySequence == sequence else { return }
            playback = nil
            cover = nil
            tracker.reset()
            scrub = nil
            phase = .idle
            onPlayback(nil)
        case .result(let id, let ok):
            if id == pendingID { releasePending(failed: !ok) }
        case .error:
            break
        }
    }

    // MARK: Sources

    /// The player's display name for the chooser and labels.
    func name(of source: MusicSource) -> String {
        source.name ?? NSRunningApplication.runningApplications(withBundleIdentifier: source.displayBundleID).first?.localizedName
            ?? source.displayBundleID
    }

    var currentSourceName: String? {
        guard let playback else { return nil }
        if let source = sources.first(where: { $0.pid == playback.pid }) { return name(of: source) }
        return NSRunningApplication(processIdentifier: playback.pid)?.localizedName
    }

    var showsChooser: Bool { sources.count > 1 || chosenPID != nil || (phase == .idle && !sources.isEmpty) }
    var isAutomatic: Bool { selection.chosen == nil }

    /// A source picked by hand, or Automatic with nil. Picking what is already in effect does nothing.
    func choose(_ source: MusicSource?) {
        guard selection.choose(source?.key) else { return }
        chosenPID = selection.chosen?.pid
        onRestart()
        reselect()
    }

    private func reselect() {
        guard reader.isWanted, let discovery else { return }
        let result = selection.resolve(discovery, includeOthers: options.includeOtherPlayers, now: now, alive: Self.isAlive)
        sources = result.listed
        chosenPID = result.chosenPID
        scheduleBridgeCheck(result.nextDeadline)
        let wanted = selection.extraCandidates
        if result.follow != follow {
            // A different player: retire the old controls at once, so no gesture can reach it.
            follow = result.follow
            extras = wanted
            playback = nil
            cover = nil
            tracker.reset()
            scrub = nil
            releasePending(failed: false)
            phase = follow == nil ? .idle : .waiting
            sendTarget()
            if follow == nil { onPlayback(nil) }
        } else if wanted != extras {
            extras = wanted
            sendTarget(advancing: false)
        } else if follow == nil, phase == .waiting {
            phase = .idle
        }
    }

    private func sendTarget(advancing: Bool = true) {
        if advancing { sequence += 1 }
        reader.send(.target(sequence: sequence, follow: follow, extra: extras))
    }

    /// Whether a process still runs as that app, so a reused pid cannot keep another app's choice.
    nonisolated static func isAlive(_ key: MusicSourceKey) -> Bool {
        guard kill(key.pid, 0) == 0 || errno == EPERM else { return false }
        if let bundle = NSRunningApplication(processIdentifier: key.pid)?.bundleIdentifier { return bundle == key.bundleID }
        return true
    }

    // MARK: Transport

    var canControl: Bool { phase == .ready && playback?.direct == true }
    var canSkipNext: Bool { canControl && !isPending && playback?.capabilities.canSkipNext != false }
    var canSkipPrevious: Bool { canControl && !isPending && playback?.capabilities.canSkipPrevious != false }
    var hidesNext: Bool { playback?.capabilities.canSkipNext == false }
    var hidesPrevious: Bool { playback?.capabilities.canSkipPrevious == false }
    var canSeek: Bool {
        guard canControl, let playback else { return false }
        return playback.capabilities.canSeek == true && (playback.duration ?? 0) > 0 && playback.hasPosition
    }

    func playPause() {
        guard let playback, canControl, !isPending else { return }
        let rate = playback.isPlaying ? max(playback.rate, 1) : 0
        let action = MusicPlayPause.action(rate: rate, capabilities: playback.capabilities)
        send { .transport(id: $0, action: action, pid: playback.pid, revision: playback.revision) }
    }

    /// Skips forward or back. False when nothing can skip that way (the swipe then does nothing).
    @discardableResult
    func skip(forward: Bool) -> Bool {
        guard let playback, forward ? canSkipNext : canSkipPrevious else { return false }
        return send { .transport(id: $0, action: forward ? .next : .previous, pid: playback.pid, revision: playback.revision) }
    }

    /// The position to draw now: the scrub while it holds, else the reading moved on by the clock.
    func position(at time: Double) -> Double? {
        guard let playback, let elapsed = playback.elapsed else { return nil }
        let live = MusicTime.position(elapsed: elapsed, readAt: readAt, now: time, playing: playback.isPlaying,
                                      rate: playback.rate, duration: playback.duration)
        if let scrub, scrub.holds(position: live, readAt: readAt, revision: playback.revision, now: time) { return scrub.value }
        return live
    }

    /// A timeline drag began (true) or ended (false). The thumb follows the pointer; one seek goes out
    /// on release, bound to the recording the drag started on.
    func scrubEditing(_ began: Bool, value: Double) {
        guard let playback, canSeek else { scrub = nil; return }
        if began {
            scrub = MusicScrub(revision: playback.revision, value: value)
            return
        }
        guard var current = scrub, current.revision == playback.revision else { scrub = nil; return }
        current.move(to: value)
        current.release(at: now)
        scrub = current
        let position = min(max(0, current.value), playback.duration ?? 0)
        send { .seek(id: $0, pid: playback.pid, revision: playback.revision, position: position) }
        scrubCheck?.cancel()
        scrubCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MusicScrub.settleTime + 0.05))
            guard !Task.isCancelled, let self, let scrub = self.scrub, scrub.releasedAt != nil else { return }
            if !scrub.holds(position: nil, readAt: nil, revision: self.playback?.revision, now: self.now) { self.scrub = nil }
        }
    }

    func scrubMoved(to value: Double) { scrub?.move(to: value) }

    @discardableResult
    private func send(_ make: (Int) -> MusicCommand) -> Bool {
        guard !isPending else { return false }
        let id = nextID
        nextID += 1
        guard reader.send(make(id)) else {
            commandFailed = true
            return false
        }
        pendingID = id
        isPending = true
        pendingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.pendingID == id else { return }
            self.releasePending(failed: true)
        }
        return true
    }

    private func releasePending(failed: Bool) {
        let hadPending = pendingID != nil
        pendingTimeout?.cancel()
        pendingTimeout = nil
        pendingID = nil
        isPending = false
        if failed { commandFailed = true } else if hadPending { commandFailed = false }
    }

    /// Brings the player forward with all its windows, or launches it.
    func openPlayer() {
        guard let bundle = playback?.displayBundleID ?? sources.first(where: { $0.pid == chosenPID })?.displayBundleID else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Timers

    private func scheduleBridgeCheck(_ deadline: Double?) {
        bridgeCheck?.cancel()
        guard let deadline else { return }
        let delay = max(0, deadline - now) + 0.01
        bridgeCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reselect()
        }
    }

    private func scheduleCoverCheck() {
        coverCheck?.cancel()
        guard let deadline = tracker.deadline else { return }
        let delay = max(0, deadline - now) + 0.01
        coverCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.tracker.expire(now: self.now)
            self.cover = self.tracker.shown
        }
    }
}
