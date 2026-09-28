import Combine
import IslandKit
import SwiftUI

/// Timer, Pomodoro and stopwatch. One session at a time, kept in memory only; while it exists it owns
/// the closed island's timer strip, and its finish raises the "Time is up" notice and alarm. Hiding
/// the section on the Content tab discards the session and withdraws the Controls tile.
@MainActor
final class TimerSection: IslandSection {
    let id = IslandSectionID.timer
    private unowned let environment: IslandEnvironment
    private let engine: TimerEngine
    private let control: IslandControlModel
    private var visibility: AnyCancellable?
    private var pageVisible = false

    init(environment: IslandEnvironment) {
        self.environment = environment
        engine = TimerEngine(environment: environment)
        control = IslandControlModel(.timer) { [weak environment] in environment?.open(.timer) }
        environment.register(control)
        visibility = environment.settingsStore.$value
            .map { $0.isVisible(.timer) }
            .removeDuplicates()
            .sink { [weak self] shown in self?.visibilityChanged(shown) }
    }

    var availability: IslandAvailability { .available }

    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight {
        if let session = engine.session { return .fixed(TimerPageLayout.activeHeight(mode: session.mode)) }
        let mode = engine.preferences.value.mode
        return .fixed(TimerPageLayout.setup(mode: mode, width: context.width, budget: context.budget).height)
    }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(TimerPage(engine: engine, preferences: engine.preferences, context: context))
    }

    func options() -> AnyView? { AnyView(TimerOptions(engine: engine, preferences: engine.preferences)) }

    func pageDidAppear() {
        guard !pageVisible else { return }
        pageVisible = true
        engine.countdownMinutes = 15
        engine.watch()
    }

    func pageDidDisappear() {
        guard pageVisible else { return }
        pageVisible = false
        engine.unwatch()
    }

    func islandDidStart() {
        engine.islandDidStart()
        if environment.isHeadless, let demo = Self.renderDemo { engine.seedForRender(demo) }
    }

    func islandDidStop() {
        pageDidDisappear()
        engine.islandDidStop()
    }

    private func visibilityChanged(_ shown: Bool) {
        engine.setShown(shown)
        control.availability = shown ? .available
            : .unavailable("Show “Timer” on the Content tab.", fixTitle: "Show") { [weak environment] in
                environment?.actions.openSettings(.timer)
            }
    }

    /// `--timer-demo <name>` for the off-screen render harness.
    private static var renderDemo: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--timer-demo"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
