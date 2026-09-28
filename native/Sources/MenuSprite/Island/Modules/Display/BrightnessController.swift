import AppKit
import CoreGraphics
import IslandKit
import os

/// The one display option: letting the island set display brightness and take the brightness keys.
/// Off until the person opts in.
@MainActor
final class IslandDisplaySettings: ObservableObject {
    static let shared = IslandDisplaySettings()
    static let controlDisplaysKey = "MenuSprite.Island.Display.controlDisplays"

    @Published var controlDisplays: Bool {
        didSet { UserDefaults.standard.set(controlDisplays, forKey: Self.controlDisplaysKey) }
    }

    private init() { controlDisplays = UserDefaults.standard.bool(forKey: Self.controlDisplaysKey) }
}

/// A display the island can set, and how: DisplayServices for the built-in panel and Apple displays,
/// DDC/CI for other external monitors.
struct BrightnessDisplay: Identifiable, Equatable, Sendable {
    enum Route: Equatable, Sendable { case system, ddc }
    let id: CGDirectDisplayID
    let name: String
    let route: Route
    let isBuiltIn: Bool
}

/// Display routes, levels and writes for the brightness card and keys. Routes exist only while
/// "Control displays" is on and the card is visible or the keys are routed; screen changes rebuild
/// them. Brightness is not observed: the card reads levels when it appears. A display call that gets
/// stuck (a monitor mid-unplug) is abandoned rather than wedging every later one.
@MainActor
final class BrightnessController: ObservableObject {
    @Published private(set) var displays: [BrightnessDisplay] = []
    @Published private(set) var levels: [CGDirectDisplayID: Double] = [:]
    @Published private(set) var hasScanned = false
    /// The display the card controls, when the person picked one; not persisted.
    @Published var chosen: CGDirectDisplayID?
    /// The island set or stepped a level (for the brightness notice).
    var onChange: (Double) -> Void = { _ in }

    /// DisplayServices, DDC and CoreBrightness calls all run here, never on the main thread. DDC
    /// commands are paced, so a slow monitor gets longer than the audio queue before it counts as stuck.
    let work = IslandHALQueue(label: "in.prerakgada.MenuSprite.island.display", limit: 4)
    private let settings: IslandDisplaySettings
    /// Confined to the display queue; replaced when that queue is abandoned.
    private var bus = DDCBus()
    /// The newest level waiting to be written, per display; slider drags fold into it.
    private let pending = OSAllocatedUnfairLock(initialState: [CGDirectDisplayID: Double]())
    private var monitors: [CGDirectDisplayID: IslandMonitorLevel] = [:]
    private var maximums: [CGDirectDisplayID: UInt16] = [:]
    private var reading: Set<CGDirectDisplayID> = []
    private var queuedSteps: [CGDirectDisplayID: [KeyStep]] = [:]
    private var cards = 0
    private var readsMonitors = false
    private var keysNeedRoutes = false
    private var screenObserver: NSObjectProtocol?
    private var scan = 0

    /// One brightness key press, told whether it could be applied.
    struct KeyStep {
        var up: Bool
        var fine: Bool
        var done: @MainActor (Bool) -> Void
    }

    init(settings: IslandDisplaySettings) {
        self.settings = settings
        work.onStall = { [weak self] in self?.stalled() }
        work.onRecover = { [weak self] in self?.recovered() }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The card's display: the person's pick, else the built-in panel, else the first.
    var current: BrightnessDisplay? {
        displays.first { $0.id == chosen } ?? displays.first { $0.isBuiltIn } ?? displays.first
    }

    /// The display the brightness keys step: the built-in panel, else the main display.
    var keyTarget: BrightnessDisplay? {
        displays.first { $0.isBuiltIn } ?? displays.first { $0.id == CGMainDisplayID() }
    }

    // MARK: Demand

    /// `readsMonitors` is false in the settings preview, which never talks to a monitor.
    func cardAppeared(readsMonitors: Bool) {
        cards += 1
        if readsMonitors { self.readsMonitors = true }
        sync(rescan: true)
    }

    func cardDisappeared() {
        cards = max(0, cards - 1)
        if cards == 0 { readsMonitors = false }
        sync(rescan: false)
    }

    func setKeysNeedRoutes(_ needed: Bool) {
        guard needed != keysNeedRoutes else { return }
        keysNeedRoutes = needed
        sync(rescan: needed)
    }

    func controlDisplaysChanged() { sync(rescan: true) }

    private func sync(rescan: Bool) {
        guard settings.controlDisplays, cards > 0 || keysNeedRoutes else {
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil
            if !settings.controlDisplays { clear() }
            return
        }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rescan() }
            }
        }
        if rescan || !hasScanned { self.rescan() }
    }

    private func clear() {
        scan += 1
        displays = []
        levels = [:]
        monitors = [:]
        maximums = [:]
        hasScanned = false
        bus = DDCBus()
    }

    /// The stuck call's monitor channels and levels are no longer trusted. Nothing is asked again
    /// until that call returns or the screens change, so a monitor that stays stuck cannot pile up
    /// blocked threads. Key presses waiting on it are dropped rather than replayed late.
    private func stalled() {
        scan += 1
        bus = DDCBus()
        levels = [:]
        monitors = [:]
        maximums = [:]
        reading = []
        queuedSteps = [:]
    }

    private func recovered() {
        if settings.controlDisplays, cards > 0 || keysNeedRoutes { rescan() }
    }

    // MARK: Routes and levels

    private struct Scan: Sendable {
        var routes: [(id: CGDirectDisplayID, route: BrightnessDisplay.Route, builtIn: Bool)] = []
        var levels: [CGDirectDisplayID: Double] = [:]
        var maximums: [CGDirectDisplayID: UInt16] = [:]
    }

    private func rescan() {
        scan += 1
        let generation = scan
        let readMonitors = readsMonitors
        let tokens = monitors.mapValues { $0.beginRead() }
        let bus = bus
        work.run({ Self.scanDisplays(bus: bus, readMonitors: readMonitors) }) { [weak self] result in
            self?.apply(result, generation: generation, tokens: tokens)
        }
    }

    /// Connected displays with a route and, where it can be read, their level. A sleeping display is
    /// not read (the last known level stays); a sleeping monitor is left alone. Monitors are asked over
    /// DDC only when the card is really on screen.
    private nonisolated static func scanDisplays(bus: DDCBus, readMonitors: Bool) -> Scan {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return Scan() }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return Scan() }
        var scan = Scan()
        var others: [CGDirectDisplayID] = []
        for id in ids.prefix(Int(count)) {
            let builtIn = CGDisplayIsBuiltin(id) != 0
            if CGDisplayIsAsleep(id) != 0 {
                if builtIn, DisplayServicesBrightness.isAvailable { scan.routes.append((id, .system, true)) }
            } else if let level = DisplayServicesBrightness.level(of: id) {
                scan.routes.append((id, .system, builtIn))
                scan.levels[id] = level
            } else if !builtIn {
                others.append(id)
            }
        }
        let monitors = bus.assign(others)
        for id in others where monitors.contains(id) {
            scan.routes.append((id, .ddc, false))
            if readMonitors, let reading = bus.read(id) {
                scan.levels[id] = reading.level
                scan.maximums[id] = reading.maximum
            }
        }
        return scan
    }

    private func apply(_ result: Scan, generation: Int, tokens: [CGDirectDisplayID: Int]) {
        guard generation == scan else { return }
        let names = Self.screenNames()
        displays = result.routes.map { route in
            BrightnessDisplay(id: route.id, name: names[route.id] ?? (route.builtIn ? "Built-in Display" : "Display"),
                              route: route.route, isBuiltIn: route.builtIn)
        }
        for (id, level) in result.levels {
            guard displays.first(where: { $0.id == id })?.route == .ddc else {
                levels[id] = level
                continue
            }
            var monitor = monitors[id] ?? IslandMonitorLevel()
            // A level the island set while the monitor was being read wins over the read.
            if monitor.finishRead(level, token: tokens[id] ?? monitor.beginRead(), now: now) { levels[id] = level }
            monitors[id] = monitor
        }
        maximums.merge(result.maximums) { $1 }
        hasScanned = true
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        return names
    }

    // MARK: Setting and stepping

    /// Sets a level from the card (shown at once, written in the background, newest value wins) or
    /// from a key step, which is written as is and told whether it landed.
    func setLevel(_ level: Double, for display: BrightnessDisplay, done: (@MainActor (Bool) -> Void)? = nil) {
        guard level.isFinite else { done?(false); return }
        let level = min(1, max(0, level))
        levels[display.id] = level
        if display.route == .ddc { monitors[display.id, default: IslandMonitorLevel()].set(level, now: now) }
        write(level, to: display, done: done)
        onChange(level)
    }

    private func write(_ level: Double, to display: BrightnessDisplay, done: (@MainActor (Bool) -> Void)?) {
        let id = display.id
        let route = display.route
        let maximum = maximums[id] ?? 100
        let bus = bus
        let pending = pending
        let coalesce = done == nil
        if coalesce { pending.withLock { $0[id] = level } }
        work.run({ () -> Bool in
            var value = level
            if coalesce {
                // An earlier job already wrote a newer drag value.
                guard let newest = pending.withLock({ $0.removeValue(forKey: id) }) else { return true }
                value = newest
            }
            switch route {
            case .system: return DisplayServicesBrightness.setLevel(value, of: id)
            case .ddc: return bus.write(value, maximum: maximum, to: id)
            }
        }) { ok in done?(ok) }
    }

    /// One brightness key step on the key target. `done` says whether it was applied, so a key that
    /// could not be is handed back to macOS.
    func step(up: Bool, fine: Bool, done: @escaping @MainActor (Bool) -> Void) {
        guard let target = keyTarget else { done(false); return }
        guard target.route == .system else {
            stepMonitor(target, KeyStep(up: up, fine: fine, done: done))
            return
        }
        // The panel's live level: Control Center and the ambient light sensor move it too.
        let id = target.id
        let fallback = levels[id] ?? 0.5
        let pending = pending
        work.run({ () -> Double? in
            if let queued = pending.withLock({ $0.removeValue(forKey: id) }) { _ = DisplayServicesBrightness.setLevel(queued, of: id) }
            let next = IslandBrightnessStep.apply(current: DisplayServicesBrightness.level(of: id) ?? fallback, up: up, fine: fine)
            return DisplayServicesBrightness.setLevel(next, of: id) ? next : nil
        }) { [weak self] next in
            guard let next else { done(false); return }
            self?.levels[id] = next
            self?.onChange(next)
            done(true)
        }
    }

    /// A monitor step after a pause reads the monitor first; steps during that read wait for it.
    private func stepMonitor(_ display: BrightnessDisplay, _ step: KeyStep) {
        let id = display.id
        if reading.contains(id) {
            queuedSteps[id, default: []].append(step)
            return
        }
        let monitor = monitors[id] ?? IslandMonitorLevel()
        guard monitor.needsRead(now: now) else {
            applySteps([step], to: display)
            return
        }
        reading.insert(id)
        queuedSteps[id] = [step]
        monitors[id] = monitor
        let token = monitor.beginRead()
        let bus = bus
        work.run({ bus.read(id) }) { [weak self] result in self?.monitorRead(display, result, token: token) }
    }

    private func monitorRead(_ display: BrightnessDisplay, _ result: IslandDDC.Reading?, token: Int) {
        reading.remove(display.id)
        if let result {
            monitors[display.id]?.finishRead(result.level, token: token, now: now)
            maximums[display.id] = result.maximum
        }
        applySteps(queuedSteps.removeValue(forKey: display.id) ?? [], to: display)
    }

    private func applySteps(_ steps: [KeyStep], to display: BrightnessDisplay) {
        guard !steps.isEmpty else { return }
        var level = monitors[display.id]?.level ?? levels[display.id] ?? 0.5
        for step in steps { level = IslandBrightnessStep.apply(current: level, up: step.up, fine: step.fine) }
        let dones = steps.map(\.done)
        setLevel(level, for: display) { ok in dones.forEach { $0(ok) } }
    }
}
