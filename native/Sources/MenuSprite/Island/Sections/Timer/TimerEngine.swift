import AppKit
import Combine
import IslandKit
import SwiftUI

/// Seconds on a clock that keeps counting while the Mac sleeps, so a deadline set before sleep is
/// still right after it.
enum TimerClock {
    private static let origin = ContinuousClock.now

    static func now() -> Double { seconds(origin.duration(to: .now)) }

    static func instant(_ seconds: Double) -> ContinuousClock.Instant { origin.advanced(by: .seconds(seconds)) }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

/// Runs the one timer session: its completion wait, the once-a-second redraw aligned to the shown
/// second, the alarm, the closed island's strip and the finished notice. Idle, it runs nothing. While
/// the island is suspended (locked, asleep, turned off) the wait and the alarm stop but the deadline
/// keeps counting; on return an overdue timer completes once and rings. Nothing survives a relaunch.
@MainActor
final class TimerEngine: ObservableObject {
    @Published private(set) var slot = TimerSlot()
    /// Bumped on every aligned tick so readings on screen redraw.
    @Published private(set) var tick = 0
    /// The countdown the ruler would start. Deliberately not remembered: 15 minutes each time the
    /// page appears.
    @Published var countdownMinutes = 15

    let preferences: TimerPreferences
    private unowned let environment: IslandEnvironment
    private var alarm = TimerAlarm()
    private let sound = TimerSound()
    private var isStarted = false
    private var isShown = true
    private var watchers = 0
    private var completionTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var alarmTask: Task<Void, Never>?
    /// What the published strip was built with.
    private var strip: (wing: CGFloat, running: Bool)?
    private var measured: (shape: String, wing: CGFloat)?
    private var stripHeight: CGFloat = 32
    private var heightObservation: AnyCancellable?
    private var pageShape: String?

    init(environment: IslandEnvironment) {
        self.environment = environment
        preferences = TimerPreferences(defaults: environment.isHeadless ? nil : .standard)
    }

    var session: TimerSession? { slot.session }

    // MARK: Actions

    func start() {
        guard isStarted, isShown else { return }
        let now = TimerClock.now()
        let settings = preferences.value
        let new: TimerSession? = switch settings.mode {
        case .timer: .countdown(minutes: countdownMinutes, at: now)
        case .pomodoro: .pomodoro(settings.plan, at: now)
        case .stopwatch: .stopwatch(at: now)
        }
        guard slot.start(new) else { return }
        sessionChanged()
    }

    func pause() {
        let now = TimerClock.now()
        if let completion = slot.update({ $0.pause(at: now) }) ?? nil {
            finished(completion, at: now)
        } else {
            sessionChanged()
        }
    }

    func resume() {
        let now = TimerClock.now()
        guard slot.update({ $0.resume(at: now) }) == true else { return }
        sessionChanged()
    }

    /// "Start Short break", "Start Long break", "Start Focus".
    func startNextPhase() {
        let now = TimerClock.now()
        guard slot.update({ $0.startNextPhase(at: now) }) == true else { return }
        silenceAlarm()
        sessionChanged()
    }

    /// Cancel or Done: the whole session goes, and the page previews a countdown again.
    func dismiss() {
        silenceAlarm()
        guard session != nil else { return }
        slot.dismiss()
        sessionChanged()
    }

    func setMode(_ mode: TimerMode) {
        preferences.update { $0.mode = mode }
        refreshPageShape()
    }

    func setSound(_ on: Bool) {
        preferences.update { $0.sound = on }
        syncAlarm()
    }

    func setPlan(_ change: (inout PomodoroPlan) -> Void) {
        preferences.update { change(&$0.plan) }
    }

    /// Keeps the island open while one of the page's menus is up.
    func holdOpen(_ hold: Bool) { environment.actions.holdOpen(hold) }

    /// A gentle tap as the ruler passes a minute, when the island's haptics are on.
    func minuteTick() {
        let settings = environment.settings
        guard settings.enabled, settings.haptics, !environment.isHeadless else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    // MARK: Readings

    func reading(at now: Double = TimerClock.now()) -> Double { session?.reading(at: now) ?? 0 }

    func clockText(at now: Double = TimerClock.now()) -> String {
        guard let session else { return "" }
        let value = session.reading(at: now)
        return session.phase.countsDown ? TimerFormat.clock(countdown: value) : TimerFormat.clock(stopwatch: value)
    }

    func stripText(at now: Double = TimerClock.now()) -> String {
        guard let session else { return "" }
        let value = session.reading(at: now)
        return session.phase.countsDown ? TimerFormat.strip(countdown: value) : TimerFormat.strip(stopwatch: value)
    }

    /// The timer's own mark beside the camera.
    var stripSymbol: String {
        guard let session else { return "timer" }
        if session.isFinished { return "checkmark.circle" }
        if session.isPaused { return "pause.circle" }
        return session.phase == .stopwatch ? "stopwatch" : "timer"
    }

    // MARK: Lifecycle

    func islandDidStart() {
        guard !isStarted else { return }
        isStarted = true
        stripHeight = environment.stripHeight
        heightObservation = environment.$stripHeight.removeDuplicates()
            .sink { [weak self] height in self?.stripHeightChanged(height) }
        // A timer that ran out while the island was away completes once now, with a fresh alarm.
        if !checkDue() { sessionChanged() }
        syncAlarm()
    }

    func islandDidStop() {
        guard isStarted else { return }
        isStarted = false
        heightObservation = nil
        completionTask?.cancel(); completionTask = nil
        stopTicking()
        syncAlarm()
        sound.release()
        environment.activities.set(nil, for: .timer)
        strip = nil
    }

    /// The section's checkbox in Settings › Content. Hiding it discards any session.
    func setShown(_ shown: Bool) {
        isShown = shown
        if !shown { dismiss() }
    }

    /// A view showing a ticking reading appeared (the page, or the strip's reading).
    func watch() {
        watchers += 1
        syncTicking()
        if watchers == 1 { didTick() }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        syncTicking()
    }

    // MARK: Session changes

    private func sessionChanged() {
        armCompletion()
        syncTicking()
        publishStrip()
        refreshPageShape()
    }

    /// "Is it due?" Completes an overdue countdown exactly once. Returns true when it completed.
    @discardableResult
    private func checkDue() -> Bool {
        guard isStarted else { return false }
        let now = TimerClock.now()
        guard let completion = slot.update({ $0.complete(at: now) }) ?? nil else { return false }
        finished(completion, at: now)
        return true
    }

    private func finished(_ completion: TimerCompletion, at now: Double) {
        alarm.arm(at: now)
        syncAlarm()
        sessionChanged()
        guard isStarted, isShown else { return }
        environment.notices.post(IslandNotice(kind: .timerFinished,
                                              style: .text(symbol: IslandSectionID.timer.symbol, image: nil,
                                                           title: completion.title, detail: completion.detail),
                                              label: "\(completion.title), \(completion.detail)"))
    }

    private func armCompletion() {
        completionTask?.cancel(); completionTask = nil
        guard isStarted, let deadline = session?.deadline else { return }
        completionTask = Task { [weak self] in
            try? await Task.sleep(until: TimerClock.instant(deadline), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            // A wake a hair early re-arms rather than dropping the completion.
            if !self.checkDue() { self.armCompletion() }
        }
    }

    // MARK: Ticking

    private func syncTicking() {
        let wanted = isStarted && watchers > 0 && session?.isRunning == true
        if !wanted { stopTicking(); return }
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while let delay = self?.nextTickDelay() {
                try? await Task.sleep(for: .seconds(delay), clock: .continuous)
                if Task.isCancelled { return }
                self?.didTick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Just after the shown second changes; nil when there is nothing more to show.
    private func nextTickDelay() -> Double? {
        guard let session, session.isRunning else { return nil }
        let reading = session.reading(at: TimerClock.now())
        guard let delay = TimerTicks.delay(reading: reading, countsDown: session.phase.countsDown) else { return nil }
        return max(0.01, delay) + 0.005
    }

    private func didTick() {
        tick &+= 1
        publishStrip()
    }

    // MARK: The closed island

    /// Publishes the strip only when it appears, goes, changes width or starts/stops running; the
    /// reading itself ticks inside the strip by observing this engine.
    private func publishStrip() {
        guard isStarted, isShown, let session else {
            if strip != nil { environment.activities.set(nil, for: .timer) }
            strip = nil
            return
        }
        let text = stripText()
        let wing = wing(for: text, shape: TimerFormat.shape(text))
        if let strip, strip.wing == wing, strip.running == session.isRunning { return }
        strip = (wing, session.isRunning)
        environment.activities.set(IslandCompactStrip(kind: .timer, wing: wing, minimumRoom: TimerStripMetrics.minimumRoom,
                                                      left: AnyView(TimerStripMark(engine: self)),
                                                      right: AnyView(TimerStripReading(engine: self)),
                                                      outline: .orange, isRunning: session.isRunning), for: .timer)
    }

    /// Measures the reading only when its shape changes ("10m" → "9m"), never every second.
    private func wing(for text: String, shape: String) -> CGFloat {
        if let measured, measured.shape == shape { return measured.wing }
        let height = min(IslandBarHeight.valid.upperBound, max(IslandBarHeight.valid.lowerBound, stripHeight))
        let font = NSFont.monospacedDigitSystemFont(ofSize: TimerStripMetrics.readingFontSize(height: height), weight: .medium)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let wing = TimerStripMetrics.wing(fit: TimerStripMetrics.fit(readingWidth: width, height: height))
        measured = (shape, wing)
        return wing
    }

    /// The island moved to a display with a different camera height: fit the wings again.
    private func stripHeightChanged(_ height: CGFloat) {
        guard height != stripHeight else { return }
        stripHeight = height
        measured = nil
        publishStrip()
    }

    /// The page's height depends on whether a session exists and on the mode; tell the shell when it
    /// changes, and only then.
    private func refreshPageShape() {
        let shape = session.map { "active.\($0.mode.rawValue)" } ?? "setup.\(preferences.value.mode.rawValue)"
        guard shape != pageShape else { return }
        pageShape = shape
        environment.invalidate()
    }

    // MARK: Alarm

    private func syncAlarm() {
        let soundOn = preferences.value.sound && !environment.isHeadless
        switch alarm.sync(soundOn: soundOn, suspended: !isStarted, now: TimerClock.now()) {
        case .start: startRinging()
        case .stop: stopRinging()
        case .none: break
        }
    }

    private func silenceAlarm() {
        alarm.acknowledge()
        stopRinging()
        sound.release()
    }

    private func startRinging() {
        alarmTask?.cancel()
        alarmTask = Task { [weak self] in
            while let delay = self?.ring() {
                try? await Task.sleep(for: .seconds(delay), clock: .continuous)
                if Task.isCancelled { return }
            }
        }
    }

    private func stopRinging() {
        alarmTask?.cancel()
        alarmTask = nil
        sound.stop()
    }

    /// Rings once; returns the wait before the next ring, or nil when the five minutes are spent.
    private func ring() -> Double? {
        let now = TimerClock.now()
        guard alarm.isRinging, alarm.isWithinLimit(at: now) else { return nil }
        sound.play()
        return alarm.nextRing(after: now)
    }

    // MARK: Render harness

    /// Seeds a session for `--island-render … --start --timer-demo <name>` so the page and strip can be
    /// checked off screen. Headless only; never rings (the alarm is silent headless).
    func seedForRender(_ name: String) {
        guard environment.isHeadless else { return }
        let now = TimerClock.now()
        let plan = preferences.value.plan
        switch name {
        case "setup-pomodoro": setMode(.pomodoro); return
        case "setup-stopwatch": setMode(.stopwatch); return
        case "countdown": slot.start(.countdown(minutes: 15, at: now - 30))
        case "hours": slot.start(.countdown(minutes: 180, at: now - 5100))
        case "seconds": slot.start(.countdown(minutes: 1, at: now - 18))
        case "pomodoro": slot.start(.pomodoro(plan, at: now - 61))
        case "stopwatch": slot.start(.stopwatch(at: now - 725))
        case "paused":
            slot.start(.countdown(minutes: 15, at: now - 300))
            _ = slot.update { $0.pause(at: now) }
        case "finished": slot.start(.countdown(minutes: 1, at: now - 61))
        case "soon": slot.start(.countdown(minutes: 1, at: now - 58.5))
        case "break": slot.start(.pomodoro(plan, at: now - Double(plan.focusMinutes * 60) - 1))
        default: return
        }
        if !checkDue() { sessionChanged() }
    }
}

/// The finished-timer sound: the system's Glass chime, or the alert beep if it is missing. Loaded
/// on the first ring and released once the timer is dismissed.
@MainActor
final class TimerSound {
    private static let path = "/System/Library/Sounds/Glass.aiff"
    private var sound: NSSound?
    private var loaded = false

    func play() {
        if !loaded {
            loaded = true
            sound = NSSound(contentsOfFile: Self.path, byReference: true)
        }
        guard let sound else { NSSound.beep(); return }
        sound.stop()
        sound.play()
    }

    func stop() { sound?.stop() }

    func release() {
        stop()
        sound = nil
        loaded = false
    }
}
