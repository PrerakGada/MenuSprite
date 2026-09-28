import AppKit
import Combine
import CoreAudio
import IslandKit

/// One column of the mixer as the page draws it.
struct MixerRow: Identifiable, Equatable {
    var app: MixerApp
    var gain: Double
    /// The output chosen for this app, if any.
    var route: String?
    var routeMissing: Bool
    var isPinned: Bool
    var canMoveLeft: Bool
    var canMoveRight: Bool
    /// The last attempt to apply this app's level or output failed or hung; it plays untouched.
    var couldNotApply = false

    var id: String { app.id }
    /// Apps with a stable identity can be pinned, moved and hidden.
    var isArrangeable: Bool { app.storageKey != nil }
}

/// Runs the per-app mixer: lists apps with audio, keeps one engine per adjusted app, watches that
/// every engine keeps rendering and fails open when one does not.
///
/// Nothing is observed unless the page is visible or an app has its own level or output while the
/// island runs; with neither, there are no listeners, no timers and no engines. Engines are only ever
/// built for apps the person adjusted, and never without System Audio Recording consent.
@MainActor
final class MixerController: ObservableObject {
    @Published private(set) var rows: [MixerRow] = []
    @Published private(set) var outputs: [MixerDevice] = []
    /// Nil until the first read comes back; nothing is tapped before it does.
    @Published private(set) var permission: MixerPermission.Status?
    /// A build failed with no engine running and consent could not be read: treat it as missing consent.
    @Published private(set) var consentSuspect = false
    @Published private(set) var hasScanned = false

    let store: MixerStore
    let isPreview: Bool
    private let systemAudio: IslandSystemAudio
    private let headless: Bool
    /// Levels and routes of apps with no stable identity, for this session only (keyed by row).
    private var session = MixerPreferences()

    private var running = false
    private var sectionShown = true
    private var pageVisible = false
    private var active = false
    private var latest: MixerScan?

    private lazy var observer = MixerObserver(changed: Self.hop(self) { $0.halChanged() })
    /// Builds run side by side, at most four at once, so one build hung in a wedged HAL cannot hold up
    /// every other app; each also has a deadline (`MixerBuildTokens.deadline`).
    private let buildQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "in.prerakgada.MenuSprite.mixer.build"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let rateQueue = DispatchQueue(label: "in.prerakgada.MenuSprite.mixer.rate", qos: .utility)
    private let stopQueue = DispatchQueue(label: "in.prerakgada.MenuSprite.mixer.stop", qos: .userInitiated, attributes: .concurrent)
    private let teardownQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "in.prerakgada.MenuSprite.mixer.teardown"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private var engines: [String: MixerEngine] = [:]
    private var editing: Set<String> = []
    private var tokens = MixerBuildTokens()
    private var recovery = MixerRecovery()
    private var renderCheck = MixerRenderCheck()
    private var grace = MixerObjectGrace()
    private var slot = MixerRefreshSlot()
    private var burst = MixerBurst()
    private var checkTasks: [String: Task<Void, Never>] = [:]
    private var buildDeadlines: [String: Task<Void, Never>] = [:]
    /// Rows whose last build failed or hung, shown as "could not apply" until something changes.
    private var unapplied: Set<String> = []
    private var graceTasks: [String: Task<Void, Never>] = [:]
    private var trailingRefresh: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var pendingSwitch: String?
    private var subscriptions: Set<AnyCancellable> = []

    init(store: MixerStore, systemAudio: IslandSystemAudio, headless: Bool) {
        self.store = store
        self.systemAudio = systemAudio
        self.headless = headless
        isPreview = false
        systemAudio.$output.receive(on: DispatchQueue.main)
            .sink { [weak self] output in self?.outputChanged(output?.uid) }
            .store(in: &subscriptions)
        systemAudio.$error.receive(on: DispatchQueue.main)
            .sink { [weak self] error in if error != nil { self?.pendingSwitch = nil } }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.didWake() }
            .store(in: &subscriptions)
    }

    /// A controller showing fixed rows, for renders and previews. It never touches the HAL.
    init(preview rows: [MixerRow], outputs: [MixerDevice], permission: MixerPermission.Status, systemAudio: IslandSystemAudio) {
        store = MixerStore(defaults: nil)
        self.systemAudio = systemAudio
        headless = true
        isPreview = true
        self.rows = rows
        self.outputs = outputs
        self.permission = permission
        hasScanned = true
    }

    // MARK: - Demand

    func setRunning(_ running: Bool, sectionShown: Bool) {
        self.running = running
        self.sectionShown = sectionShown
        if running { refreshPermission() }
        sync()
    }

    func setSectionShown(_ shown: Bool) {
        sectionShown = shown
        sync()
    }

    func setPageVisible(_ visible: Bool) {
        pageVisible = visible
        if visible {
            // Opening the page gives a suspected consent failure one more try.
            if consentSuspect {
                consentSuspect = false
                recovery.resetAll()
            }
            refreshPermission()
        }
        sync()
    }

    /// The island stopped: every engine goes, every listener and timer with it.
    func stop() {
        running = false
        pageVisible = false
        sync()
    }

    private var wantsEngines: Bool { running && sectionShown && !headless }

    private var hasAdjustments: Bool {
        let saved = store.preferences
        return !saved.volumes.isEmpty || !saved.routes.isEmpty || !session.volumes.isEmpty || !session.routes.isEmpty
    }

    private var wantsObservation: Bool {
        !headless && permission?.allowsTaps == true && !consentSuspect && (pageVisible || (wantsEngines && hasAdjustments))
    }

    private func sync() {
        guard !isPreview else { return }
        if wantsObservation, !active {
            active = true
            observer.start()
            requestRefresh()
        } else if !wantsObservation, active {
            deactivate()
        }
        if !wantsEngines { Array(engines.keys).forEach(release) }
    }

    private func deactivate() {
        active = false
        observer.stop()
        slot.discard()
        tokens.invalidateAll()
        burst.reset()
        trailingRefresh?.cancel()
        wakeTask?.cancel()
        Array(engines.keys).forEach(release)
        graceTasks.values.forEach { $0.cancel() }
        graceTasks = [:]
        buildDeadlines.values.forEach { $0.cancel() }
        buildDeadlines = [:]
        unapplied.removeAll()
        grace.forgetAll()
        latest = nil
        rows = []
        hasScanned = false
        MixerIcons.keep([])
    }

    // MARK: - Permission

    private func refreshPermission() {
        guard !isPreview else { return }
        Self.readPermission(Self.hop(self) { (controller: MixerController, status: MixerPermission.Status) in controller.permissionRead(status) })
    }

    nonisolated private static func readPermission(_ deliver: @escaping @Sendable (MixerPermission.Status) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { deliver(MixerPermission.status()) }
    }

    private func permissionRead(_ status: MixerPermission.Status) {
        if status != permission { permission = status }
        if status == .granted { consentSuspect = false }
        sync()
    }

    /// The only place a consent prompt can come from: the permission view's button.
    func requestPermission() {
        guard !headless, !isPreview else { return }
        MixerPermission.request { [weak self] status in self?.permissionRead(status) }
    }

    // MARK: - Refresh

    private func halChanged() { requestRefresh() }

    private func requestRefresh() {
        guard active else { return }
        switch burst.request(now: Self.now) {
        case .now:
            runRefresh()
        case .later(let delay):
            trailingRefresh = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.burst.fired(now: Self.now)
                self.runRefresh()
            }
        case .none:
            break
        }
    }

    private func runRefresh() {
        guard active, let pass = slot.begin() else { return }
        observer.scan(Self.hop(self) { (controller: MixerController, scan: MixerScan) in controller.finishRefresh(pass, scan) })
    }

    private func finishRefresh(_ pass: UInt64, _ scan: MixerScan) {
        let (publish, again) = slot.finish(pass)
        if publish, active { apply(scan) }
        if again { runRefresh() }
    }

    private func apply(_ scan: MixerScan) {
        if let previous = latest, previous.defaultOutput != scan.defaultOutput || previous.outputs.map(\.uid) != scan.outputs.map(\.uid) {
            tokens.invalidateAll()
        }
        latest = scan
        if outputs != scan.outputs { outputs = scan.outputs }
        if !hasScanned { hasScanned = true }
        publishRows()
        reconcileAll()
        for (id, _) in engines where checkTasks[id] == nil { check(id) }
    }

    private func didWake() {
        guard active else { return }
        renderCheck.forgetAll()
        recovery.resetAll()
        checkTasks.values.forEach { $0.cancel() }
        checkTasks = [:]
        requestRefresh()
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.reconcileAll()
        }
    }

    // MARK: - Rows

    /// A keyed app's saved level, or a session-only app's; nil at 100 %.
    private func savedGain(_ app: MixerApp) -> Double? {
        if let key = app.storageKey { return store.preferences.volumes[key] }
        return session.volumes[app.id]
    }

    private func savedRoute(_ app: MixerApp) -> String? {
        guard !app.isBypassed else { return nil }
        if let key = app.storageKey { return store.preferences.routes[key] }
        return session.routes[app.id]
    }

    private func gain(_ app: MixerApp) -> Double {
        app.isBypassed ? MixerLevel.unity : savedGain(app) ?? MixerLevel.unity
    }

    private func isHidden(_ app: MixerApp) -> Bool {
        let saved = store.preferences
        return MixerListing.isHidden(storageKey: app.storageKey, hidden: saved.hidden, showsFinder: saved.showsFinder)
    }

    private func publishRows() {
        guard let scan = latest else { return }
        let saved = store.preferences
        let available = Set(scan.outputs.map(\.uid))
        let listed = MixerListing.withFinder(scan.apps, showsFinder: saved.showsFinder, finderPID: scan.finderPID).filter { !isHidden($0) }
        let shown = saved.arrangement.order(listed).filter { app in
            MixerListing.isShown(playing: app.isPlaying, gain: gain(app), routed: savedRoute(app) != nil, hideInactive: saved.hideInactive)
        }
        let keys = shown.compactMap(\.storageKey)
        let next = shown.map { app -> MixerRow in
            let route = savedRoute(app)
            let key = app.storageKey
            return MixerRow(app: app, gain: gain(app), route: route,
                            routeMissing: MixerTarget(route: route, available: available, defaultOutput: scan.defaultOutput).routeMissing,
                            isPinned: key.map(saved.arrangement.isPinned) ?? false,
                            canMoveLeft: key.map { saved.arrangement.canStep($0, forward: false, visible: keys) } ?? false,
                            canMoveRight: key.map { saved.arrangement.canStep($0, forward: true, visible: keys) } ?? false,
                            couldNotApply: unapplied.contains(app.id))
        }
        if next != rows { rows = next }
        MixerIcons.keep(Set(next.map(\.id)))
    }

    // MARK: - Engines

    private func app(_ id: String) -> MixerApp? { latest?.apps.first { $0.id == id } }

    private func reconcileAll() {
        guard let scan = latest else { return }
        let listed = Set(scan.apps.map(\.id))
        scan.apps.forEach { reconcile($0.id, $0) }
        engines.keys.filter { !listed.contains($0) }.forEach { reconcile($0, nil) }
    }

    /// The configuration this app should run with now, or nil when it should play untouched.
    private func desired(_ app: MixerApp) -> MixerEngineConfiguration? {
        guard let scan = latest, !app.isBypassed, !isHidden(app) else { return nil }
        let route = savedRoute(app)
        let target = MixerTarget(route: route, available: Set(scan.outputs.map(\.uid)), defaultOutput: scan.defaultOutput)
        guard MixerEnginePolicy.needsEngine(hasAudio: app.hasAudio, target: target, defaultOutput: scan.defaultOutput,
                                            savedGain: savedGain(app), savedRoute: route), let device = target.uid else { return nil }
        return MixerEngineConfiguration(objects: app.objects, device: device)
    }

    private func reconcile(_ id: String, _ app: MixerApp?) {
        guard wantsEngines, permission?.allowsTaps == true, let scan = latest else { return release(id) }
        if let engine = engines[id], !scan.outputs.contains(where: { $0.uid == engine.configuration.device }) {
            release(id)
        }
        let hasAudio = app?.hasAudio ?? false
        guard hasAudio || engines[id] != nil else { return }
        switch grace.decide(id, hasAudio: hasAudio, now: Self.now) {
        case .wait(let delay):
            graceTasks[id]?.cancel()
            graceTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.graceTasks[id] = nil
                self.reconcile(id, self.app(id))
            }
            return
        case .release:
            return release(id)
        case .proceed:
            break
        }
        guard let app else { return }
        let level = gain(app)
        guard let configuration = desired(app) else {
            // A drag passing through 100 % keeps its engine until the drag ends.
            if editing.contains(id), let engine = engines[id] { engine.renderer.gain = level } else { release(id) }
            return
        }
        engines[id]?.renderer.gain = level
        guard engines[id]?.configuration != configuration, recovery.mayBuild(id, configuration),
              let token = tokens.begin(id, now: Self.now) else { return }
        Self.build(configuration, gain: level, on: buildQueue, rateQueue: rateQueue,
                   Self.hop(self) { (controller: MixerController, result: Result<MixerEngine, any Error>) in
                       controller.install(token, configuration, result)
                   })
        watchDeadline(token, configuration, after: MixerBuildTokens.deadline)
    }

    nonisolated private static func build(_ configuration: MixerEngineConfiguration, gain: Double, on queue: OperationQueue,
                                          rateQueue: DispatchQueue, _ deliver: @escaping @Sendable (Result<MixerEngine, any Error>) -> Void) {
        queue.addOperation { deliver(Result { try MixerEngine.build(configuration, gain: gain, rateQueue: rateQueue) }) }
    }

    /// A build still running at its deadline is given up: the app keeps playing untouched and the row
    /// says so. If the build ever finishes, its token is refused and the engine is torn down.
    private func watchDeadline(_ token: MixerBuildTokens.Token, _ configuration: MixerEngineConfiguration, after delay: TimeInterval) {
        buildDeadlines[token.row] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            switch self.tokens.checkDeadline(token, now: Self.now) {
            case .settled:
                break
            case .wait(let remaining):
                self.watchDeadline(token, configuration, after: remaining)
            case .expired:
                self.buildDeadlines[token.row] = nil
                self.recovery.recordHang(token.row, configuration)
                self.markUnapplied(token.row)
            }
        }
    }

    private func markUnapplied(_ id: String) {
        guard engines[id] == nil else { return }
        unapplied.insert(id)
        publishRows()
    }

    /// Installs a finished build if it is still wanted. Replacements are built first and the old engine
    /// stops only after the new one runs, so the app never falls back to full volume in between.
    private func install(_ token: MixerBuildTokens.Token, _ configuration: MixerEngineConfiguration, _ result: Result<MixerEngine, any Error>) {
        let current = tokens.finish(token)
        let id = token.row
        if current { buildDeadlines.removeValue(forKey: id)?.cancel() }
        switch result {
        case .success(let engine):
            guard current, active, wantsEngines, let app = app(id), desired(app) == configuration else {
                discard(engine)
                if current, active { reconcile(id, app(id)) }
                return
            }
            engine.renderer.gain = gain(app)
            let old = engines.updateValue(engine, forKey: id)
            old.map(discard)
            if unapplied.remove(id) != nil { publishRows() }
            consentSuspect = false
            renderCheck.forget(id)
            check(id)
        case .failure:
            guard current else { return }
            recovery.recordDeath(id, configuration)
            if engines[id] == nil, permission == .unknown {
                consentSuspect = true
                sync()
            } else {
                markUnapplied(id)
            }
        }
    }

    private func release(_ id: String) {
        checkTasks.removeValue(forKey: id)?.cancel()
        renderCheck.forget(id)
        if let engine = engines.removeValue(forKey: id) { discard(engine) }
    }

    /// Stops the engine at once (the app is audible again), then destroys it on the bounded queue.
    private func discard(_ engine: MixerEngine) { Self.discard(engine, stopQueue: stopQueue, teardown: teardownQueue) }

    nonisolated private static func discard(_ engine: MixerEngine, stopQueue: DispatchQueue, teardown: OperationQueue) {
        stopQueue.async {
            engine.stop()
            teardown.addOperation { engine.destroy() }
        }
    }

    /// The watchdog: while an adjusted app plays, its render counter must move within the window.
    private func check(_ id: String) {
        checkTasks.removeValue(forKey: id)?.cancel()
        guard let engine = engines[id] else { return renderCheck.forget(id) }
        switch renderCheck.evaluate(id, playing: app(id)?.isPlaying ?? false, count: engine.renderer.cycles, now: Self.now) {
        case .idle:
            break
        case .recheck(let delay):
            checkTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.check(id)
            }
        case .wedged:
            recovery.recordDeath(id, engine.configuration)
            release(id)
            reconcile(id, app(id))
        }
    }

    // MARK: - Actions from the page

    private func change(_ row: MixerRow, persist: Bool = true, _ edit: (inout MixerPreferences, String) -> Void) {
        if let key = row.app.storageKey {
            store.update(persist: persist) { edit(&$0, key) }
        } else {
            edit(&session, row.id)
        }
        recovery.reset(row.id)
        unapplied.remove(row.id)
        publishRows()
        reconcile(row.id, app(row.id))
        sync()
    }

    func setGain(_ gain: Double, for row: MixerRow) {
        change(row, persist: !editing.contains(row.id)) { $0.setGain(gain, for: $1) }
        if engines[row.id] != nil { check(row.id) }
    }

    /// A fader drag began or ended; the level is written to disk and the engine decided when it ends.
    func setEditing(_ row: MixerRow, _ isEditing: Bool) {
        if isEditing {
            editing.insert(row.id)
        } else {
            editing.remove(row.id)
            store.save()
            reconcile(row.id, app(row.id))
            sync()
        }
    }

    func toggleMute(_ row: MixerRow) { change(row) { $0.toggleMute($1) } }
    func reset(_ row: MixerRow) { change(row) { $0.setGain(MixerLevel.unity, for: $1) } }
    func setRoute(_ uid: String?, for row: MixerRow) { change(row) { $0.setRoute(uid, for: $1) } }

    func togglePin(_ row: MixerRow) {
        guard let key = row.app.storageKey else { return }
        let visible = rows.compactMap(\.app.storageKey)
        store.update { row.isPinned ? $0.arrangement.unpin(key) : $0.arrangement.pin(key, visible: visible) }
        publishRows()
    }

    func move(_ row: MixerRow, forward: Bool) {
        guard let key = row.app.storageKey else { return }
        let visible = rows.compactMap(\.app.storageKey)
        store.update { $0.arrangement.step(key, forward: forward, visible: visible) }
        publishRows()
    }

    /// Hidden apps always play untouched: their engine goes with them.
    func hide(_ row: MixerRow) {
        guard let key = row.app.storageKey else { return }
        store.update { MixerListing.hide(storageKey: key, name: row.app.name, in: &$0.hidden, showsFinder: &$0.showsFinder) }
        release(row.id)
        publishRows()
        sync()
    }

    func unhide(_ key: String) {
        store.update { $0.hidden[key] = nil }
        publishRows()
        reconcileAll()
    }

    func setShowsFinder(_ shows: Bool) {
        store.update { $0.showsFinder = shows }
        publishRows()
        reconcileAll()
    }

    func setHideInactive(_ hide: Bool) {
        store.update { $0.hideInactive = hide }
        publishRows()
    }

    /// Choosing the system output also sends every app there; routes clear once the switch lands.
    func selectSystemOutput(_ device: IslandAudioDevice) {
        guard !isPreview else { return }
        pendingSwitch = device.uid
        slot.invalidate()
        tokens.invalidateAll()
        systemAudio.selectOutput(device)
        requestRefresh()
    }

    private func outputChanged(_ uid: String?) {
        guard let pending = pendingSwitch, uid == pending else { return }
        pendingSwitch = nil
        store.update { $0.outputSwitched(succeeded: true) }
        session.outputSwitched(succeeded: true)
        publishRows()
        reconcileAll()
        sync()
    }

    // MARK: - Hops

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A callback for other threads that runs `body` on the main actor, if the controller still exists.
    nonisolated private static func hop(_ controller: MixerController, _ body: @escaping @MainActor (MixerController) -> Void) -> @Sendable () -> Void {
        { [weak controller] in
            DispatchQueue.main.async { MainActor.assumeIsolated { if let controller { body(controller) } } }
        }
    }

    nonisolated private static func hop<Value: Sendable>(_ controller: MixerController,
                                                         _ body: @escaping @MainActor (MixerController, Value) -> Void) -> @Sendable (Value) -> Void {
        { [weak controller] value in
            DispatchQueue.main.async { MainActor.assumeIsolated { if let controller { body(controller, value) } } }
        }
    }
}
